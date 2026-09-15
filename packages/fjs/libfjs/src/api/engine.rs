//! # JavaScript Engine
//!
//! This module provides the core engine implementation that manages
//! the JavaScript runtime lifecycle and bridge communication.
//!
//! ## Simplified API
//!
//! The engine provides direct async methods:
//! - `eval()` - Evaluate JavaScript code
//! - `declare_new_module()` - Register a module without executing
//! - `declare_new_modules()` - Register multiple modules
//! - `evaluate_module()` - Register and execute a module
//! - `declare_new_bytecode_module()` - Register precompiled module bytecode
//! - `evaluate_bytecode_module()` - Register and execute precompiled module bytecode
//! - `evaluate_script_bytecode()` - Execute precompiled classic script bytecode
//! - `call()` - Call a function in a module
//! - `clear_pending_modules()` - Clear dynamic modules that have not been loaded yet
//! - `get_declared_modules()` - Get all module names
//! - `get_available_modules()` - Get builtin and dynamic module names
//! - `is_module_declared()` - Check if a module exists
//! - `is_module_available()` - Check if a builtin or dynamic module exists

use crate::api::error::{JsError, JsResult};
use crate::api::module::{
    DynamicModuleEntry, DynamicModuleStorage, get_loaded_dynamic_module_names,
    is_dynamic_module_loaded, mark_dynamic_module_loaded,
};
use crate::api::runtime::{
    JsAsyncContext, JsAsyncRuntime, MemoryUsage, call_module_method, result_from_maybe_promise,
    result_from_promise,
};
use crate::api::source::{
    JsBuiltinOptions, JsCode, JsEvalOptions, JsModule, JsModuleBytecode, JsModuleBytecodeBundle,
    JsScriptBytecode, get_raw_source_code,
};
use crate::api::value::JsValue;
use crate::bytecode_support::{
    eval_script_bytecode, load_module_bytecode_checked, validate_module_bundle_impl,
    validate_module_bytecode_impl, validate_script_bytecode_impl,
};
use flutter_rust_bridge::{DartFnFuture, frb};
use futures::{
    FutureExt,
    future::{AbortHandle, Abortable},
};
use rquickjs::{CatchResultExt, FromJs, Module, Object, Promise};
use std::collections::{HashMap, HashSet, VecDeque};
use std::panic::AssertUnwindSafe;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use tokio::sync::{mpsc, oneshot, Notify};

/// Type alias for the bridge callback function.
pub type BridgeCallback = dyn Fn(JsValue) -> DartFnFuture<JsResult> + Sync + Send + 'static;

/// Type alias for the host cancellation callback.
pub type BridgeCancelCallback = dyn Fn(u64) -> DartFnFuture<()> + Sync + Send + 'static;
/// Type alias for a cancellable host bridge callback.
pub type CancellableBridgeCallback =
    dyn Fn(BridgeRequest) -> DartFnFuture<JsResult> + Sync + Send + 'static;
/// Type alias for a short-lived host request starter.
pub type BridgeStartCallback = dyn Fn(BridgeRequest) -> DartFnFuture<()> + Sync + Send + 'static;
static NEXT_BRIDGE_REQUEST_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_BROKER_OWNER_ID: AtomicU64 = AtomicU64::new(1);
struct BrokerEntry {
    owner: u64,
    sender: oneshot::Sender<JsResult>,
    starter: AbortHandle,
    cancel: Arc<BridgeCancelCallback>,
    execution_id: Option<u64>,
    nested: mpsc::Sender<BrokerEval>,
    wake: Arc<Notify>,
}
struct BrokerEval {
    source: String,
    reply: oneshot::Sender<Result<JsValue, JsError>>,
}
static BROKER_PENDING: OnceLock<Mutex<HashMap<u64, BrokerEntry>>> = OnceLock::new();

fn broker_pending() -> &'static Mutex<HashMap<u64, BrokerEntry>> {
    BROKER_PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Completes a host request without acquiring a `JsEngine` opaque lock.
pub fn complete_bridge_request_global(id: u64, result: JsResult) -> Result<(), JsError> {
    let entry = broker_pending()
        .lock()
        .unwrap()
        .remove(&id)
        .ok_or_else(|| JsError::bridge("Unknown or already completed bridge request"))?;
    let result = entry.sender.send(result)
        .map_err(|_| JsError::bridge("Bridge request receiver was closed"));
    entry.wake.notify_one();
    result
}

/// Evaluates synchronous JS inside the context paused at this host request.
/// Request IDs are host-only capabilities; stale IDs cannot enter another engine.
/// Ordinary engine.eval remains queued. Promises are not synchronous host results.
pub async fn eval_bridge_request_global(id: u64, source: String) -> Result<JsValue, JsError> {
    if source.len() > 64 * 1024 {
        return Err(JsError::bridge("Nested script exceeds 64 KiB"));
    }
    let (reply, result) = oneshot::channel();
    {
        let registry = broker_pending().lock().unwrap();
        let entry = registry.get(&id)
            .ok_or_else(|| JsError::bridge("Unknown or already completed bridge request"))?;
        entry.nested.try_send(BrokerEval { source, reply })
            .map_err(|_| JsError::bridge("Nested request queue unavailable"))?;
        entry.wake.notify_one();
    }
    result.await.map_err(|_| JsError::cancelled("Bridge request ended"))?
}

/// A host bridge request with a Rust-owned monotonically increasing ID.
#[derive(Debug, Clone)]
pub struct BridgeRequest {
    /// Request identifier allocated by Rust.
    pub id: u64,
    /// Root execution owning this call; absent for the legacy eval API.
    pub execution_id: Option<u64>,
    /// JavaScript payload.
    pub value: JsValue,
}
/// Runtime configuration applied when constructing a high-level `JsEngine`.
#[frb(dart_metadata = ("freezed"))]
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct JsEngineRuntimeOptions {
    /// Hard limit, in bytes, for memory allocated by the QuickJS runtime.
    ///
    /// `None` leaves QuickJS's default memory limit unchanged.
    pub memory_limit: Option<usize>,
    /// Allocated-memory threshold, in bytes, that triggers a garbage-collection cycle.
    ///
    /// `None` leaves QuickJS's default threshold unchanged.
    pub gc_threshold: Option<usize>,
    /// Maximum native stack space, in bytes, available to JavaScript execution.
    ///
    /// The runtime clamps this value to FJS's supported asynchronous stack range.
    /// `None` keeps the FJS default.
    pub max_stack_size: Option<usize>,
    /// Optional diagnostic label associated with the QuickJS runtime.
    ///
    /// The label is metadata for diagnostics and does not affect execution semantics.
    pub info: Option<String>,
}

/// Engine state constants
const STATE_CREATED: u8 = 0;
const STATE_INITIALIZING: u8 = 1;
const STATE_RUNNING: u8 = 2;
const STATE_CLOSED: u8 = 3;

/// The JavaScript engine.
///
/// `JsEngine` provides a high-level API for executing JavaScript code,
/// managing modules, and communicating with Dart through a bridge callback.
///
/// ## Lifecycle
///
/// 1. Create an engine with `JsEngine.create(...)`
/// 2. Initialize it with `init(bridge)` or `initWithoutBridge()`
/// 3. Execute JavaScript using `eval()`, `evaluateModule()`, or `call()`
/// 4. Close when done with `close()`
///
/// ## Example
///
/// ```dart
/// final engine = await JsEngine.create(
///   builtins: JsBuiltinOptions.essential(),
/// );
/// await engine.initWithoutBridge();
/// final result = await engine.eval(source: JsCode.code('1 + 1'));
/// print(result.value); // 2
/// await engine.close();
/// ```
#[frb(opaque)]
pub struct JsEngine {
    resources: RwLock<Option<Arc<JsEngineResources>>>,
    state: AtomicU8,
}

struct JsEngineResources {
    context: JsAsyncContext,
    runtime: JsAsyncRuntime,
    cancellable: Mutex<Option<CancellableBridgeState>>,
    broker: Mutex<Option<Arc<BrokerBridgeState>>>,
}

struct CancellableBridgeState {
    pending: Arc<Mutex<HashSet<u64>>>,
    cancel: Arc<BridgeCancelCallback>,
}

struct BrokerBridgeState {
    owner: u64,
    depth: AtomicU64,
    closed: AtomicBool,
    cancel: Arc<BridgeCancelCallback>,
    executions: Mutex<ExecutionQueue>,
    active: Mutex<Vec<Arc<ScopedExecution>>>,
    wake: Arc<Notify>,
}

struct ExecutionQueue {
    running: bool,
    commands: VecDeque<ScopedCommand>,
}
struct ScopedExecution {
    id: u64,
    owner: u64,
    submitted: AtomicBool,
    cancelled: AtomicBool,
    wake: Notify,
    scheduler_wake: Arc<Notify>,
}
struct ScopedCommand {
    scope: Arc<ScopedExecution>,
    source: String,
    reply: oneshot::Sender<Result<JsValue, JsError>>,
}
static NEXT_EXECUTION: AtomicU64 = AtomicU64::new(1);
static EXECUTIONS: OnceLock<Mutex<HashMap<u64, Arc<ScopedExecution>>>> = OnceLock::new();
fn executions() -> &'static Mutex<HashMap<u64, Arc<ScopedExecution>>> {
    EXECUTIONS.get_or_init(|| Mutex::new(HashMap::new()))
}
/// Cancel only this execution, retaining its shared runtime and other executions.
pub fn cancel_scoped_execution_global(id: u64) -> bool {
    let scope = executions().lock().unwrap().get(&id).cloned();
    let Some(scope) = scope else { return false; };
    scope.cancelled.store(true, Ordering::Release);
    let cancelled = {
        let mut registry = broker_pending().lock().unwrap();
        let ids = registry.iter().filter_map(|(request_id, entry)|
            (entry.execution_id == Some(id)).then_some(*request_id)).collect::<Vec<_>>();
        ids.into_iter().filter_map(|request_id| registry.remove(&request_id)
            .map(|entry| (request_id, entry.starter, entry.cancel))).collect::<Vec<_>>()
    };
    for (request_id, starter, cancel) in cancelled {
        starter.abort();
        crate::runtime::executor::spawn_js(async move { let _ = cancel(request_id).await; });
    }
    scope.wake.notify_one();
    scope.scheduler_wake.notify_one();
    true
}
/// Release a reservation that was never submitted.
pub fn discard_scoped_execution_global(id: u64) {
    let mut entries = executions().lock().unwrap();
    if entries.get(&id).is_some_and(|s| !s.submitted.load(Ordering::Acquire)) {
        entries.remove(&id);
    }
}
fn run_scoped(ctx: &rquickjs::Ctx<'_>, state: &Arc<BrokerBridgeState>, command: ScopedCommand) {
    let scope = command.scope;
    state.active.lock().unwrap().push(scope.clone());
    let result = if scope.cancelled.load(Ordering::Acquire) || state.closed.load(Ordering::Acquire) {
        Err(JsError::cancelled("Execution cancelled"))
    } else {
        ctx.eval::<rquickjs::Value, _>(command.source)
            .and_then(|value| {
                if value.is_promise() { return Err(rquickjs::Error::new_from_js_message("Promise", "JsValue", "Scoped evaluation is synchronous")); }
                JsValue::from_js(ctx, value)
            }).catch(ctx).map_err(|error| JsError::from_caught(ctx, error))
    };
    state.active.lock().unwrap().pop();
    executions().lock().unwrap().remove(&scope.id);
    let result = if scope.cancelled.load(Ordering::Acquire) || state.closed.load(Ordering::Acquire) { Err(JsError::cancelled("Execution cancelled")) } else { result };
    let _ = command.reply.send(result);
}

#[cfg(windows)]
fn run_fiber_scheduler(ctx: &rquickjs::Ctx<'_>, state: &Arc<BrokerBridgeState>) -> Result<(), JsError> {
    use crate::runtime::fibers::{Scheduler, Fiber};
    struct Live<'a> {
        fiber: Fiber<'a>,
        scope: Arc<ScopedExecution>,
        active: Vec<Arc<ScopedExecution>>,
        depth: u64,
    }
    let runtime = unsafe {rquickjs::qjs::JS_GetRuntime(ctx.as_raw().as_ptr())};
    let scheduler = unsafe {Scheduler::new(runtime)}.map_err(|e|JsError::bridge(e.to_string()))?;
    let mut live: Vec<Live<'_>> = Vec::new();
    let mut failure = None;
    loop {
        while failure.is_none() && live.len() < 64 {
            let command = state.executions.lock().unwrap().commands.pop_front();
            let Some(command) = command else {break};
            let scope = command.scope.clone();
            match scheduler.create(||run_scoped(ctx,state,command)) {
                Ok(fiber) => live.push(Live{fiber,scope,active:Vec::new(),depth:0}),
                Err(error) => {
                    executions().lock().unwrap().remove(&scope.id);
                    failure=Some(JsError::bridge(error.to_string()));
                }
            }
        }
        if failure.is_some() {
            state.closed.store(true,Ordering::Release);
            for task in &live {task.scope.cancelled.store(true,Ordering::Release);}
        }
        for task in &mut live {
            if task.fiber.done(){continue;}
            *state.active.lock().unwrap()=std::mem::take(&mut task.active);
            state.depth.store(task.depth,Ordering::Relaxed);
            scheduler.resume(&mut task.fiber);
            task.active=std::mem::take(&mut *state.active.lock().unwrap());
            task.depth=state.depth.swap(0,Ordering::Relaxed);
            if task.fiber.failed(){
                executions().lock().unwrap().remove(&task.scope.id);
                failure=Some(JsError::bridge("Execution fiber panicked"));
            }
        }
        live.retain(|task|!task.fiber.done());
        if live.is_empty() {
            let mut queue=state.executions.lock().unwrap();
            if queue.commands.is_empty() || failure.is_some() {
                queue.running=false;
                return match failure {Some(error)=>Err(error),None=>Ok(())};
            }
            continue;
        }
        if failure.is_some(){continue;}
        if live.len()<64 && !state.executions.lock().unwrap().commands.is_empty(){continue;}
        // Notify retains a permit if completion/cancellation occurred while
        // another stack was running. Only this actor consumes it.
        tokio::runtime::Handle::current().block_on(state.wake.notified());
    }
}

impl JsEngine {
    /// Creates a new JavaScript engine with custom runtime configuration.
    ///
    /// ## Parameters
    /// - `builtins`: Optional builtin module configuration
    /// - `modules`: Optional list of additional modules to register
    /// - `runtimeOptions`: Optional runtime-level limits and metadata applied
    ///   before the engine context is created
    pub async fn create(
        builtins: Option<JsBuiltinOptions>,
        modules: Option<Vec<JsModule>>,
        runtime_options: Option<JsEngineRuntimeOptions>,
    ) -> Result<Self, JsError> {
        let runtime = JsAsyncRuntime::create(builtins, modules).await?;
        if let Some(options) = runtime_options {
            if let Some(limit) = options.memory_limit {
                runtime.set_memory_limit(limit).await;
            }
            if let Some(threshold) = options.gc_threshold {
                runtime.set_gc_threshold(threshold).await;
            }
            if let Some(limit) = options.max_stack_size {
                runtime.set_max_stack_size(limit).await;
            }
            if let Some(info) = options.info {
                runtime.set_info(info).await?;
            }
        }
        let context = JsAsyncContext::from(&runtime).await?;

        Ok(Self {
            resources: RwLock::new(Some(Arc::new(JsEngineResources {
                runtime,
                context,
                cancellable: Mutex::new(None),
                broker: Mutex::new(None),
            }))),
            state: AtomicU8::new(STATE_CREATED),
        })
    }

    #[cfg(test)]
    pub(crate) fn new_for_test(runtime: JsAsyncRuntime, context: JsAsyncContext) -> Self {
        Self {
            resources: RwLock::new(Some(Arc::new(JsEngineResources {
                runtime,
                context,
                cancellable: Mutex::new(None),
                broker: Mutex::new(None),
            }))),
            state: AtomicU8::new(STATE_CREATED),
        }
    }

    #[cfg(test)]
    pub(crate) fn runtime_for_test(&self) -> JsAsyncRuntime {
        self.resources_for_test().runtime.clone()
    }

    #[cfg(test)]
    fn resources_for_test(&self) -> Arc<JsEngineResources> {
        self.resources
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .expect("engine resources were already released")
            .clone()
    }

    fn resources(&self) -> Result<Arc<JsEngineResources>, JsError> {
        self.resources
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .cloned()
            .ok_or_else(|| JsError::engine("Engine is closed"))
    }

    fn take_resources(&self) -> Option<Arc<JsEngineResources>> {
        self.resources
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
    }

    /// Returns whether the engine has been closed.
    ///
    /// Once closed, the engine cannot be used anymore.
    #[frb(sync, getter)]
    pub fn closed(&self) -> bool {
        self.state.load(Ordering::Acquire) == STATE_CLOSED
    }

    /// Returns whether the engine is running and ready for execution.
    ///
    /// The engine is running after `init()` or `initWithoutBridge()`
    /// has been called successfully.
    #[frb(sync, getter)]
    pub fn running(&self) -> bool {
        self.state.load(Ordering::Acquire) == STATE_RUNNING
    }

    /// Ensures runtime-level controls can be used on this engine.
    fn ensure_runtime_accessible(&self) -> Result<Arc<JsEngineResources>, JsError> {
        let resources = self.resources()?;
        match self.state.load(Ordering::Acquire) {
            STATE_CREATED => Ok(resources),
            STATE_RUNNING => {
                self.ensure_no_unhandled_job_errors(&resources.runtime)?;
                Ok(resources)
            }
            STATE_CLOSED => Err(JsError::engine("Engine is closed")),
            STATE_INITIALIZING => Err(JsError::engine("Engine is initializing")),
            _ => Err(JsError::engine("Engine is in an invalid state")),
        }
    }

    /// Ensures the engine is in running state.
    fn ensure_running(&self) -> Result<Arc<JsEngineResources>, JsError> {
        let resources = self.resources()?;
        match self.state.load(Ordering::Acquire) {
            STATE_RUNNING => {
                self.ensure_no_unhandled_job_errors(&resources.runtime)?;
                Ok(resources)
            }
            STATE_CLOSED => Err(JsError::engine("Engine is closed")),
            STATE_INITIALIZING => Err(JsError::engine("Engine is initializing")),
            STATE_CREATED => Err(JsError::engine("Engine is not initialized")),
            _ => Err(JsError::engine("Engine is in an invalid state")),
        }
    }

    fn format_unhandled_job_errors(errors: &[String]) -> String {
        format!(
            "Unhandled JavaScript background error: {}",
            errors.join("\n")
        )
    }

    fn ensure_no_unhandled_job_errors(&self, runtime: &JsAsyncRuntime) -> Result<(), JsError> {
        let errors = runtime.take_unhandled_job_errors();
        if errors.is_empty() {
            Ok(())
        } else {
            Err(JsError::runtime(Self::format_unhandled_job_errors(&errors)))
        }
    }

    async fn with_foreground_js_result<F>(&self, f: F) -> Result<JsValue, JsError>
    where
        F: for<'js> AsyncFnOnce(rquickjs::Ctx<'js>, u64) -> JsResult + Send + 'static,
    {
        let resources = self.ensure_running()?;
        resources
            .context
            .with_foreground_js_result(f)
            .await
            .into_result()
    }

    fn already_loaded_error(module_name: String) -> JsError {
        JsError::module(
            Some(module_name),
            None,
            "Module has already been loaded in this context and cannot be redefined; \
             create a new context to replace it",
        )
    }

    fn ensure_unique_module_names<'a>(
        names: impl IntoIterator<Item = &'a str>,
    ) -> Result<(), JsError> {
        if let Some(duplicate) = first_duplicate_name(names) {
            return Err(JsError::module(
                Some(duplicate.clone()),
                None,
                format!("Duplicate module name in request: '{duplicate}'"),
            ));
        }
        Ok(())
    }

    /// Declares pre-resolved dynamic modules in the engine context.
    async fn declare_dynamic_modules(
        &self,
        entries: Vec<(String, DynamicModuleEntry)>,
    ) -> Result<(), JsError> {
        let single = entries.len() == 1;
        self.with_foreground_js_result(async move |ctx, _checkpoint| {
            let conflicts: Vec<_> = entries
                .iter()
                .filter(|(name, _)| is_dynamic_module_loaded(&ctx, name))
                .map(|(name, _)| name.clone())
                .collect();
            if let Some(first) = conflicts.first() {
                return JsResult::Err(if single {
                    Self::already_loaded_error(first.clone())
                } else {
                    JsError::module(
                        Some(first.clone()),
                        None,
                        format!(
                            "Loaded dynamic modules cannot be redefined in this context: {}",
                            conflicts.join(", ")
                        ),
                    )
                });
            }
            let Some(storage) = ctx.userdata::<DynamicModuleStorage>() else {
                return JsResult::Err(JsError::storage("Module storage not initialized"));
            };
            storage
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .extend(entries);
            JsResult::Ok(JsValue::None)
        })
        .await
        .map(|_| ())
    }

    /// Registers a dynamic module and runs its top-level code.
    async fn evaluate_dynamic_module(
        &self,
        module_name: String,
        entry: DynamicModuleEntry,
    ) -> Result<JsValue, JsError> {
        let resources = self.ensure_running()?;
        let driver = resources.runtime.driver.clone();
        let shutdown = resources.runtime.shutdown();
        resources
            .context
            .with_foreground_js_result(async move |ctx, checkpoint| {
                if is_dynamic_module_loaded(&ctx, &module_name) {
                    return JsResult::Err(Self::already_loaded_error(module_name));
                }
                let Some(storage) = ctx.userdata::<DynamicModuleStorage>() else {
                    return JsResult::Err(JsError::storage("Module storage not initialized"));
                };

                let res = match entry {
                    DynamicModuleEntry::Source(source) => {
                        storage
                            .write()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .insert(
                                module_name.clone(),
                                DynamicModuleEntry::Source(source.clone()),
                            );
                        Module::evaluate(ctx.clone(), module_name.clone(), source)
                    }
                    DynamicModuleEntry::Bytecode(bytes) => {
                        let loaded = load_module_bytecode_checked(
                            ctx.clone(),
                            &module_name,
                            &bytes,
                        )
                        .and_then(|module| {
                            let embedded_name: String = module.name()?;
                            if embedded_name != module_name {
                                return Err(rquickjs::Error::new_loading_message(
                                    module_name.clone(),
                                    format!(
                                        "Bytecode module name mismatch: expected '{}', found '{}'",
                                        module_name, embedded_name
                                    ),
                                ));
                            }
                            let (_module, promise) = module.eval()?;
                            Ok(promise)
                        });
                        if loaded.is_ok() {
                            storage
                                .write()
                                .unwrap_or_else(std::sync::PoisonError::into_inner)
                                .insert(module_name.clone(), DynamicModuleEntry::Bytecode(bytes));
                        }
                        loaded
                    }
                };

                if res.is_ok() {
                    mark_dynamic_module_loaded(&ctx, &module_name);
                }
                let driver = driver.clone();
                result_from_promise(&ctx, res, shutdown, move |source| {
                    driver.remove_error_source_since(checkpoint, source);
                })
                .await
            })
            .await
            .into_result()
    }

    /// Transitions the engine into the initializing state.
    fn begin_init(&self) -> Result<(), JsError> {
        let current = self.state.load(Ordering::Acquire);
        if current == STATE_CLOSED {
            return Err(JsError::engine("Engine is closed"));
        }
        if current == STATE_INITIALIZING {
            return Err(JsError::engine("Engine is initializing"));
        }
        if current == STATE_RUNNING {
            return Err(JsError::engine("Engine is already initialized"));
        }

        self.state
            .compare_exchange(
                STATE_CREATED,
                STATE_INITIALIZING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| JsError::engine("Failed to initialize engine - invalid state"))?;
        Ok(())
    }

    /// Advances the engine-owned runtime by one scheduler step.
    #[cfg(test)]
    pub(crate) async fn execute_pending_job(&self) -> Result<bool, JsError> {
        let resources = self.ensure_runtime_accessible()?;
        resources.runtime.execute_pending_job().await
    }

    /// Runs the engine-owned runtime until quiescent.
    #[cfg(test)]
    pub(crate) async fn idle(&self) -> Result<(), JsError> {
        let resources = self.ensure_runtime_accessible()?;
        resources.runtime.idle().await;
        Ok(())
    }

    /// Returns whether the engine-owned runtime still has work pending.
    #[cfg(test)]
    pub(crate) async fn is_job_pending(&self) -> Result<bool, JsError> {
        let resources = self.ensure_runtime_accessible()?;
        Ok(resources.runtime.is_job_pending().await)
    }

    /// Returns memory usage statistics for the engine-owned runtime.
    pub async fn memory_usage(&self) -> Result<MemoryUsage, JsError> {
        let resources = self.ensure_runtime_accessible()?;
        Ok(resources.runtime.memory_usage().await)
    }

    /// Forces a garbage collection pass on the engine-owned runtime.
    pub async fn run_gc(&self) -> Result<(), JsError> {
        let resources = self.ensure_runtime_accessible()?;
        resources.runtime.run_gc().await;
        Ok(())
    }

    /// Sets the garbage collection threshold on the engine-owned runtime.
    pub async fn set_gc_threshold(&self, threshold: usize) -> Result<(), JsError> {
        let resources = self.ensure_runtime_accessible()?;
        resources.runtime.set_gc_threshold(threshold).await;
        Ok(())
    }

    /// Sets runtime metadata on the engine-owned runtime.
    pub async fn set_info(&self, info: String) -> Result<(), JsError> {
        let resources = self.ensure_runtime_accessible()?;
        resources.runtime.set_info(info).await
    }

    /// Sets the max stack size on the engine-owned runtime.
    pub async fn set_max_stack_size(&self, limit: usize) -> Result<(), JsError> {
        let resources = self.ensure_runtime_accessible()?;
        resources.runtime.set_max_stack_size(limit).await;
        Ok(())
    }

    /// Sets the memory limit on the engine-owned runtime.
    pub async fn set_memory_limit(&self, limit: usize) -> Result<(), JsError> {
        let resources = self.ensure_runtime_accessible()?;
        resources.runtime.set_memory_limit(limit).await;
        Ok(())
    }

    /// Commits initialization after all setup steps succeed.
    fn finish_init(&self) -> Result<(), JsError> {
        self.state
            .compare_exchange(
                STATE_INITIALIZING,
                STATE_RUNNING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| JsError::engine("Failed to finalize engine initialization"))?;
        Ok(())
    }

    /// Rolls back the init state when initialization fails.
    fn rollback_init(&self) {
        let _ = self.state.compare_exchange(
            STATE_INITIALIZING,
            STATE_CREATED,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
    }

    /// Marks the engine as closed and returns the previous state.
    ///
    /// Closing always wins, even while an `init()` is still in flight: the
    /// in-flight initialization observes the CLOSED state when it tries to
    /// commit and reports failure to its own caller.
    fn begin_close(&self) -> Result<u8, JsError> {
        loop {
            let current = self.state.load(Ordering::Acquire);
            match current {
                STATE_CLOSED => return Ok(STATE_CLOSED),
                STATE_CREATED | STATE_INITIALIZING | STATE_RUNNING => {
                    if self
                        .state
                        .compare_exchange(
                            current,
                            STATE_CLOSED,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        )
                        .is_ok()
                    {
                        return Ok(current);
                    }
                }
                _ => return Err(JsError::engine("Engine is in an invalid state")),
            }
        }
    }

    /// Initializes the engine with a bridge callback for Dart-JS communication.
    ///
    /// The bridge callback is invoked when JavaScript calls `fjs.bridge_call(value)`.
    /// This enables bidirectional communication between Dart and JavaScript.
    ///
    /// ## Parameters
    /// - `bridge`: A callback function that receives a `JsValue` from JavaScript
    ///   and returns a `JsResult` back to JavaScript
    ///
    /// ## Throws
    /// - If the engine is already closed
    /// - If the engine is already initialized
    /// - If initialization is already in progress
    ///
    /// ## Example
    /// ```dart
    /// await engine.init(bridge: (value) async {
    ///   print('Received from JS: \$value');
    ///   return JsResult.ok(JsValue.string('Response from Dart'));
    /// });
    /// ```
    pub async fn init(
        &self,
        bridge: impl Fn(JsValue) -> DartFnFuture<JsResult> + Sync + Send + 'static,
    ) -> Result<(), JsError> {
        self.begin_init()?;

        let resources = match self.resources() {
            Ok(resources) => resources,
            Err(error) => {
                self.rollback_init();
                return Err(error);
            }
        };
        let bridge = Arc::new(bridge);
        let attachment = resources.context.global_attachment.clone();
        let shutdown = resources.runtime.shutdown();

        let init_result = resources
            .context
            .with_js(async move |ctx| {
                if let Some(attachment) = &attachment
                    && let Err(e) = attachment.attach(&ctx)
                {
                    return Err(JsError::context(format!(
                        "Failed to attach global context: {e}"
                    )));
                }
                if let Err(e) = register_fjs(ctx.clone(), bridge, shutdown) {
                    return Err(JsError::bridge(format!(
                        "Failed to register fjs bridge: {e}"
                    )));
                }
                Ok(())
            })
            .await;

        if init_result.is_err() {
            self.rollback_init();
        }

        init_result?;
        if let Err(error) = self.finish_init() {
            self.rollback_init();
            // close() may have won the race while we were setting up the
            // context; undo our setup so the closed engine does not keep the
            // bridge object (and any captured Dart closure) alive.
            if self.closed() {
                crate::runtime::teardown::cleanup_async_engine_immediately(
                    &resources.context,
                    &resources.runtime,
                )
                .await;
            }
            return Err(error);
        }
        Ok(())
    }

    /// Initializes the engine with a cancellable host bridge.
    pub async fn init_cancellable(
        &self,
        bridge: impl Fn(BridgeRequest) -> DartFnFuture<JsResult> + Sync + Send + 'static,
        cancel: impl Fn(u64) -> DartFnFuture<()> + Sync + Send + 'static,
    ) -> Result<(), JsError> {
        self.begin_init()?;
        let resources = self.resources()?;
        let pending = Arc::new(Mutex::new(HashSet::new()));
        let cancel: Arc<BridgeCancelCallback> = Arc::new(cancel);
        let attachment = resources.context.global_attachment.clone();
        let shutdown = resources.runtime.shutdown();
        let bridge = Arc::new(bridge);
        let cancel_for_registration = cancel.clone();
        let result = resources
            .context
            .with_js(async move |ctx| {
                if let Some(attachment) = &attachment {
                    attachment.attach(&ctx).map_err(|e| {
                        JsError::context(format!("Failed to attach global context: {e}"))
                    })?;
                }
                register_fjs_cancellable(ctx, bridge, cancel_for_registration, shutdown)
                    .map_err(|e| JsError::bridge(format!("Failed to register fjs bridge: {e}")))
            })
            .await;
        if result.is_err() {
            self.rollback_init();
            return result;
        }
        resources
            .cancellable
            .lock()
            .unwrap()
            .replace(CancellableBridgeState { pending, cancel });
        self.finish_init()
    }

    /// Initializes a two-stage bridge whose host operation completes through Rust.
    pub async fn init_broker(
        &self,
        start: impl Fn(BridgeRequest) -> DartFnFuture<()> + Sync + Send + 'static,
        cancel: impl Fn(u64) -> DartFnFuture<()> + Sync + Send + 'static,
    ) -> Result<(), JsError> {
        self.begin_init()?;
        let resources = match self.resources() {
            Ok(resources) => resources,
            Err(error) => {
                self.rollback_init();
                return Err(error);
            }
        };
        let cancel: Arc<BridgeCancelCallback> = Arc::new(cancel);
        let state = Arc::new(BrokerBridgeState {
            owner: NEXT_BROKER_OWNER_ID.fetch_add(1, Ordering::Relaxed),
            depth: AtomicU64::new(0),
            closed: AtomicBool::new(false),
            cancel: cancel.clone(),
            executions: Mutex::new(ExecutionQueue { running: false, commands: VecDeque::new() }),
            active: Mutex::new(Vec::new()),
            wake: Arc::new(Notify::new()),
        });
        let interrupt_state = state.clone();
        resources.runtime.install_execution_interrupt(move || {
            interrupt_state.active.lock().unwrap().last()
                .is_some_and(|scope| scope.cancelled.load(Ordering::Acquire))
        }).await;
        // Publish ownership before setup can yield, so close also owns init races.
        resources.broker.lock().unwrap().replace(state.clone());
        let start: Arc<BridgeStartCallback> = Arc::new(start);
        let attachment = resources.context.global_attachment.clone();
        let shutdown = resources.runtime.shutdown();
        let state_for_registration = state.clone();
        let result = resources
            .context
            .with_js(async move |ctx| {
                if let Some(attachment) = &attachment {
                    attachment.attach(&ctx).map_err(|e| {
                        JsError::context(format!("Failed to attach global context: {e}"))
                    })?;
                }
                register_fjs_broker(ctx, start, state_for_registration, shutdown)
                    .map_err(|e| JsError::bridge(format!("Failed to register fjs broker: {e}")))
            })
            .await;
        if result.is_err() {
            resources.broker.lock().unwrap().take();
            resources.runtime.clear_execution_interrupt().await;
            self.rollback_init();
            return result;
        }
        if let Err(error) = self.finish_init() {
            resources.broker.lock().unwrap().take();
            resources.runtime.clear_execution_interrupt().await;
            self.rollback_init();
            if self.closed() {
                crate::runtime::teardown::cleanup_async_engine_immediately(
                    &resources.context,
                    &resources.runtime,
                )
                .await;
            }
            return Err(error);
        }
        Ok(())
    }

    /// Reserve a host-only execution capability bound to this engine.
    pub fn create_scoped_execution(&self) -> Result<u64, JsError> {
        let resources = self.resources()?;
        let state = resources.broker.lock().unwrap().clone().ok_or_else(|| JsError::bridge("Broker not initialized"))?;
        let mut registry = executions().lock().unwrap();
        if state.closed.load(Ordering::Acquire) { return Err(JsError::cancelled("Engine closed")); }
        let id = NEXT_EXECUTION.fetch_add(1, Ordering::Relaxed);
        registry.insert(id, Arc::new(ScopedExecution {
            id, owner: state.owner, submitted: AtomicBool::new(false),
            cancelled: AtomicBool::new(false), wake: Notify::new(), scheduler_wake: state.wake.clone(),
        }));
        Ok(id)
    }

    /// Execute with an independent cancellation scope. Waiting host calls pump
    /// this same queue, so shared state remains live during synchronous I/O.
    pub async fn eval_scoped(&self, id: u64, source: String) -> Result<JsValue, JsError> {
        if source.len() > 1024 * 1024 { return Err(JsError::bridge("Scoped script exceeds limit")); }
        let resources = self.resources()?;
        let state = resources.broker.lock().unwrap().clone().ok_or_else(|| JsError::bridge("Broker not initialized"))?;
        let scope = executions().lock().unwrap().get(&id).cloned().ok_or_else(|| JsError::bridge("Unknown execution"))?;
        if scope.owner != state.owner { return Err(JsError::bridge("Execution owner mismatch")); }
        let (reply, result) = oneshot::channel();
        let start = {
            let mut queue = state.executions.lock().unwrap();
            if state.closed.load(Ordering::Acquire) { return Err(JsError::cancelled("Engine closed")); }
            if queue.commands.len() >= 64 { return Err(JsError::bridge("Execution queue full")); }
            if scope.submitted.swap(true, Ordering::AcqRel) { return Err(JsError::bridge("Execution already submitted")); }
            queue.commands.push_back(ScopedCommand { scope, source, reply });
            let start = !queue.running;
            queue.running = true;
            start
        };
        state.wake.notify_one();
        if start {
            let driver_state = state.clone();
            tokio::spawn(async move {
                let state = driver_state.clone();
                let outcome: Result<(), JsError> = resources.context.with_js(async move |ctx| {
                    #[cfg(windows)]
                    { tokio::task::block_in_place(|| run_fiber_scheduler(&ctx, &state)) }
                    #[cfg(not(windows))]
                    {
                    loop {
                        let next = {
                            let mut queue = state.executions.lock().unwrap();
                            let next = queue.commands.pop_front();
                            if next.is_none() { queue.running = false; }
                            next
                        };
                        match next { Some(command) => run_scoped(&ctx, &state, command), None => break }
                    }
                    Ok(())
                    }
                }).await;
                if let Err(error) = outcome {
                    let mut queue = driver_state.executions.lock().unwrap();
                    queue.running = false;
                    for command in queue.commands.drain(..) {
                        executions().lock().unwrap().remove(&command.scope.id);
                        let _ = command.reply.send(Err(JsError::cancelled(error.to_string())));
                    }
                }
            });
        }
        result.await.map_err(|_| JsError::cancelled("Execution driver ended"))?
    }

    /// Completes a previously started host bridge request.
    pub fn complete_bridge_request(&self, id: u64, result: JsResult) -> Result<(), JsError> {
        complete_bridge_request_global(id, result)
    }

    /// JavaScript code can still run, but `fjs.bridge_call()` will not be available.
    ///
    /// ## Throws
    /// - If the engine is already closed
    /// - If the engine is already initialized
    /// - If initialization is already in progress
    ///
    /// ## Example
    /// ```dart
    /// await engine.initWithoutBridge();
    /// ```
    pub async fn init_without_bridge(&self) -> Result<(), JsError> {
        self.begin_init()?;

        let resources = match self.resources() {
            Ok(resources) => resources,
            Err(error) => {
                self.rollback_init();
                return Err(error);
            }
        };
        let attachment = resources.context.global_attachment.clone();
        let init_result = resources
            .context
            .with_js(async move |ctx| {
                if let Some(attachment) = &attachment
                    && let Err(e) = attachment.attach(&ctx)
                {
                    return Err(JsError::context(format!(
                        "Failed to attach global context: {e}"
                    )));
                }
                Ok(())
            })
            .await;

        if init_result.is_err() {
            self.rollback_init();
        }

        init_result?;
        if let Err(error) = self.finish_init() {
            self.rollback_init();
            // close() may have won the race while we were setting up the
            // context; undo our setup so the closed engine does not keep the
            // bridge object (and any captured Dart closure) alive.
            if self.closed() {
                crate::runtime::teardown::cleanup_async_engine_immediately(
                    &resources.context,
                    &resources.runtime,
                )
                .await;
            }
            return Err(error);
        }
        Ok(())
    }

    async fn close_with_mode(&self, graceful: bool) -> Result<(), JsError> {
        let previous_state = self.begin_close()?;
        let resources = if previous_state == STATE_CLOSED {
            None
        } else {
            self.take_resources()
        };

        let mut unhandled_errors = resources
            .as_ref()
            .map(|resources| resources.runtime.take_unhandled_job_errors())
            .unwrap_or_default();

        let mut callback_failed = false;
        if let Some(resources) = resources {
            // Interrupt queued/running JS before dropping senders or awaiting Dart.
            if !graceful {
                resources.runtime.request_shutdown();
            }
            let broker = resources.broker.lock().unwrap().take();
            if let Some(state) = broker {
                state.closed.store(true, Ordering::Release);
                state.wake.notify_one();
                executions().lock().unwrap().retain(|_, scope| {
                    if scope.owner != state.owner { return true; }
                    scope.cancelled.store(true, Ordering::Release);
                    scope.wake.notify_one();
                    false
                });
                let pending = {
                    let mut registry = broker_pending().lock().unwrap();
                    state.closed.store(true, Ordering::Release);
                    let ids = registry
                        .iter()
                        .filter_map(|(id, entry)| (entry.owner == state.owner).then_some(*id))
                        .collect::<Vec<_>>();
                    ids.into_iter()
                        .filter_map(|id| registry.remove(&id).map(|entry| (id, entry)))
                        .collect::<Vec<_>>()
                };
                for (id, entry) in pending {
                    entry.starter.abort();
                    drop(entry.sender);
                    if AssertUnwindSafe(async { (state.cancel)(id).await })
                        .catch_unwind()
                        .await
                        .is_err()
                    {
                        callback_failed = true;
                    }
                }
            }
            let cancellable = resources.cancellable.lock().unwrap().take();
            if let Some(state) = cancellable {
                let ids = state.pending.lock().unwrap().drain().collect::<Vec<_>>();
                for id in ids {
                    let _ = (state.cancel)(id).await;
                }
            }
            if graceful {
                crate::runtime::teardown::cleanup_async_engine_gracefully(
                    &resources.context,
                    &resources.runtime,
                )
                .await;
            } else {
                crate::runtime::teardown::cleanup_async_engine_immediately(
                    &resources.context,
                    &resources.runtime,
                )
                .await;
            }
            unhandled_errors.extend(resources.runtime.take_unhandled_job_errors());
            if !graceful {
                Self::retire_resources_after_immediate_close(resources);
            }
        }

        if callback_failed {
            Err(JsError::bridge(
                "Host cancellation callback failed after runtime shutdown",
            ))
        } else if unhandled_errors.is_empty() {
            Ok(())
        } else {
            Err(JsError::runtime(Self::format_unhandled_job_errors(
                &unhandled_errors,
            )))
        }
    }

    /// Closes the engine immediately and releases its owned resources.
    ///
    /// After close, the engine wrapper cannot be used anymore. This method
    /// marks the engine closed, requests runtime cancellation, stops the
    /// background driver, detaches the `fjs` bridge object, skips the full
    /// blocking runtime drain, and retires the remaining QuickJS resources on
    /// the JS executor. In-flight foreground operations fail with
    /// `JsError::Cancelled` instead of waiting for timers, Promise callbacks,
    /// fetches, bridge calls, or spawned work to complete.
    ///
    /// Use `closeGracefully()` when shutdown must let already-scheduled
    /// JavaScript work finish before resources are released.
    ///
    /// Closing always wins: it succeeds even while `init()` is still in
    /// flight (the interrupted `init()` reports the failure to its caller).
    ///
    /// ## Throws
    /// - If unhandled background JavaScript errors were already pending
    ///
    /// ## Example
    /// ```dart
    /// await engine.close();
    /// ```
    pub async fn close(&self) -> Result<(), JsError> {
        self.close_with_mode(false).await
    }

    /// Closes the engine after draining pending runtime work.
    ///
    /// This preserves the pre-3.2 graceful teardown behavior for runtime work:
    /// the engine stops accepting new work, detaches the bridge, drains pending
    /// timers, Promise callbacks, fetches, and spawned runtime tasks until the
    /// runtime becomes quiescent, and then runs GC. In-flight broker calls are
    /// cancelled during broker teardown and do not wait for host completion.
    ///
    /// Use `close()` for normal disposal paths where shutdown should not wait
    /// for arbitrary JavaScript background work.
    ///
    /// ## Throws
    /// - If unhandled background JavaScript errors are pending or raised during
    ///   the drain
    ///
    /// ## Example
    /// ```dart
    /// await engine.closeGracefully();
    /// ```
    pub async fn close_gracefully(&self) -> Result<(), JsError> {
        self.close_with_mode(true).await
    }

    fn retire_resources_after_immediate_close(resources: Arc<JsEngineResources>) {
        crate::runtime::executor::spawn_js(async move {
            resources.runtime.idle().await;
            resources.runtime.run_gc().await;
            drop(resources);
        });
    }

    /// Returns whether the engine-owned runtime background driver is running.
    ///
    /// Engine initialization starts the driver automatically. `close()` stops it.
    #[cfg(test)]
    pub(crate) async fn driver_running(&self) -> Result<bool, JsError> {
        let Some(resources) = self
            .resources
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .cloned()
        else {
            return Ok(false);
        };
        Ok(resources.runtime.driver_running().await)
    }

    /// Drains unhandled asynchronous JavaScript errors captured by the engine runtime.
    ///
    /// Background JavaScript failures (detached Promise chains, timer callbacks,
    /// spawned async work) cannot return an error to the original Dart call. They
    /// are queued instead and surfaced either by the next engine operation, by
    /// `close()`, or by this method.
    ///
    /// Call this periodically when you want to log background failures without
    /// letting them fail an unrelated engine call. Draining is destructive: the
    /// returned errors are removed from the queue. This method works in every
    /// engine state, including after `close()`.
    ///
    /// ## Example
    /// ```dart
    /// final errors = engine.drainUnhandledJobErrors();
    /// for (final error in errors) {
    ///   print('Background JS error: \$error');
    /// }
    /// ```
    #[frb(sync)]
    pub fn drain_unhandled_job_errors(&self) -> Vec<String> {
        self.resources
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map(|resources| resources.runtime.take_unhandled_job_errors())
            .unwrap_or_default()
    }

    /// Evaluates JavaScript code and returns the result.
    ///
    /// Supports both synchronous and asynchronous JavaScript code.
    /// Top-level await is enabled by default.
    ///
    /// ## Parameters
    /// - `source`: The JavaScript code to evaluate (string, path, or bytes)
    /// - `options`: Optional evaluation settings (defaults to promise-enabled mode)
    ///
    /// ## Returns
    /// The result of the evaluation as a `JsValue`
    ///
    /// ## Throws
    /// - If the engine is not initialized
    /// - If the engine is closed
    /// - If JavaScript execution fails
    ///
    /// ## Example
    /// ```dart
    /// // Simple expression
    /// final result = await engine.eval(source: JsCode.code('1 + 1'));
    /// print(result.value); // 2
    ///
    /// // Async code
    /// final asyncResult = await engine.eval(source: JsCode.code('''
    ///   await new Promise(resolve => setTimeout(() => resolve('done'), 100))
    /// '''));
    /// ```
    pub async fn eval(
        &self,
        source: JsCode,
        options: Option<JsEvalOptions>,
    ) -> Result<JsValue, JsError> {
        let resources = self.ensure_running()?;

        let mut options = options.unwrap_or_default();
        options.promise = Some(true);

        let source_code = get_raw_source_code(source).await?;

        let driver = resources.runtime.driver.clone();
        let shutdown = resources.runtime.shutdown();
        resources
            .context
            .with_foreground_js_result(async move |ctx, checkpoint| {
                let res = ctx.eval_with_options(source_code, options.into());
                let driver = driver.clone();
                result_from_promise(&ctx, res, shutdown, move |source| {
                    driver.remove_error_source_since(checkpoint, source);
                })
                .await
            })
            .await
            .into_result()
    }

    /// Declares a new bytecode-backed module without executing it.
    ///
    /// The bytecode must have been compiled for the same QuickJS version embedded by FJS and
    /// should only come from trusted sources.
    ///
    /// After declaration, the module can be imported by later evaluations or
    /// `call()` invocations. Once a dynamic module has been loaded in this
    /// context it cannot be replaced without creating a new context.
    ///
    /// ## Example
    /// ```dart
    /// final bytecode = await JsBytecode.compile(
    ///   module: JsModule.code(
    ///     module: 'feature/config',
    ///     code: 'export const version = "3.0.0";',
    ///   ),
    /// );
    ///
    /// await engine.declareNewBytecodeModule(module: bytecode);
    /// ```
    pub async fn declare_new_bytecode_module(
        &self,
        module: JsModuleBytecode,
    ) -> Result<(), JsError> {
        self.ensure_running()?;
        validate_module_bytecode_impl(&module.name, &module.bytes)?;
        self.declare_dynamic_modules(vec![(
            module.name,
            DynamicModuleEntry::Bytecode(module.bytes),
        )])
        .await
    }

    /// Declares multiple bytecode-backed modules without executing them.
    ///
    /// This is the bytecode counterpart to `declareNewModules(...)` and is useful
    /// when a feature depends on several precompiled modules.
    ///
    /// ## Example
    /// ```dart
    /// await engine.declareNewBytecodeModules(modules: [
    ///   coreBytecode,
    ///   helpersBytecode,
    /// ]);
    /// ```
    pub async fn declare_new_bytecode_modules(
        &self,
        modules: Vec<JsModuleBytecode>,
    ) -> Result<(), JsError> {
        self.ensure_running()?;
        Self::ensure_unique_module_names(modules.iter().map(|module| module.name.as_str()))?;
        for module in &modules {
            validate_module_bytecode_impl(&module.name, &module.bytes)?;
        }
        self.declare_dynamic_modules(
            modules
                .into_iter()
                .map(|module| (module.name, DynamicModuleEntry::Bytecode(module.bytes)))
                .collect(),
        )
        .await
    }

    /// Declares a bundle of bytecode-backed modules without executing them.
    ///
    /// The optional bundle entry is ignored during declaration. Use
    /// `evaluateBytecodeBundle(...)` when the entry module should also be
    /// executed.
    ///
    /// ## Example
    /// ```dart
    /// await engine.declareNewBytecodeBundle(bundle: pluginBundle);
    /// ```
    pub async fn declare_new_bytecode_bundle(
        &self,
        bundle: JsModuleBytecodeBundle,
    ) -> Result<(), JsError> {
        self.ensure_running()?;
        // Bundle validation already covers duplicate names and per-module
        // bytecode checks; declare directly to avoid validating twice.
        validate_module_bundle_impl(&bundle)?;
        self.declare_dynamic_modules(
            bundle
                .modules
                .into_iter()
                .map(|module| (module.name, DynamicModuleEntry::Bytecode(module.bytes)))
                .collect(),
        )
        .await
    }

    /// Declares a new module without executing it.
    ///
    /// The module will be available for import in subsequent evaluations.
    /// Use this when you need to register a module for later use.
    /// Once a dynamic module has been loaded into this context, it cannot
    /// be replaced without recreating the context.
    ///
    /// ## Parameters
    /// - `module`: The module to declare (name and source code)
    ///
    /// ## Throws
    /// - If the engine is not initialized
    /// - If module storage is not available
    ///
    /// ## Example
    /// ```dart
    /// await engine.declareNewModule(module: JsModule.code(
    ///   module: 'math-utils',
    ///   code: 'export function add(a, b) { return a + b; }',
    /// ));
    ///
    /// // Later, import and use it
    /// final result = await engine.eval(source: JsCode.code('''
    ///   const { add } = await import('math-utils');
    ///   add(1, 2)
    /// '''));
    /// ```
    pub async fn declare_new_module(&self, module: JsModule) -> Result<(), JsError> {
        self.ensure_running()?;

        let JsModule { name, source } = module;
        let source_code = get_raw_source_code(source).await?;
        self.declare_dynamic_modules(vec![(name, DynamicModuleEntry::Source(source_code))])
            .await
    }

    /// Declares multiple new modules without executing them.
    ///
    /// Convenience method for registering multiple modules at once.
    ///
    /// ## Parameters
    /// - `modules`: List of modules to declare
    ///
    /// Loaded dynamic modules cannot be redefined; recreating the context is
    /// required to replace them.
    ///
    /// ## Throws
    /// - If the engine is not initialized
    /// - If any module declaration fails
    ///
    /// ## Example
    /// ```dart
    /// await engine.declareNewModules(modules: [
    ///   JsModule.code(module: 'utils', code: 'export const VERSION = "1.0"'),
    ///   JsModule.code(module: 'helpers', code: 'export function log(x) { console.log(x); }'),
    /// ]);
    /// ```
    pub async fn declare_new_modules(&self, modules: Vec<JsModule>) -> Result<(), JsError> {
        self.ensure_running()?;
        Self::ensure_unique_module_names(modules.iter().map(|module| module.name.as_str()))?;

        let mut entries = Vec::with_capacity(modules.len());
        for module in modules {
            let JsModule { name, source } = module;
            let source_code = get_raw_source_code(source).await?;
            entries.push((name, DynamicModuleEntry::Source(source_code)));
        }
        self.declare_dynamic_modules(entries).await
    }

    /// Evaluates a module (registers and executes it).
    ///
    /// Unlike `declareNewModule`, this method also executes the module's
    /// top-level code and registers it in the current context.
    ///
    /// QuickJS module evaluation usually completes with `undefined`. Import the module
    /// afterwards if you need its exports.
    ///
    /// ## Parameters
    /// - `module`: The module to evaluate (name and source code)
    ///
    /// ## Returns
    /// The completion value of module evaluation, which is usually `undefined`
    ///
    /// ## Throws
    /// - If the engine is not initialized
    /// - If module storage is not available
    /// - If module execution fails
    /// - If the module name has already been loaded in this context
    ///
    /// ## Example
    /// ```dart
    /// await engine.evaluateModule(module: JsModule.code(
    ///   module: 'init',
    ///   code: '''
    ///     console.log("Module initializing...");
    ///     export default { version: "1.0" };
    ///   ''',
    /// ));
    ///
    /// final loaded = await engine.eval(source: JsCode.code('''
    ///   const { default: info } = await import('init');
    ///   info.version
    /// '''));
    /// ```
    pub async fn evaluate_module(&self, module: JsModule) -> Result<JsValue, JsError> {
        self.ensure_running()?;

        let JsModule { name, source } = module;
        let source_code = get_raw_source_code(source).await?;
        self.evaluate_dynamic_module(name, DynamicModuleEntry::Source(source_code))
            .await
    }

    /// Evaluates a bytecode-backed module (registers and executes it).
    ///
    /// The bytecode must have been compiled for the same embedded QuickJS version and should
    /// only be loaded from trusted sources. As with source modules, the completion value is
    /// usually `undefined`; import the module afterwards to read its exports.
    ///
    /// ## Example
    /// ```dart
    /// final bytecode = await JsBytecode.compile(
    ///   module: JsModule.code(
    ///     module: 'feature/init',
    ///     code: 'export default { ready: true };',
    ///   ),
    /// );
    ///
    /// await engine.evaluateBytecodeModule(module: bytecode);
    ///
    /// final result = await engine.eval(source: JsCode.code('''
    ///   const { default: init } = await import('feature/init');
    ///   init.ready
    /// '''));
    /// ```
    pub async fn evaluate_bytecode_module(
        &self,
        module: JsModuleBytecode,
    ) -> Result<JsValue, JsError> {
        self.ensure_running()?;
        // `load_module_bytecode_checked` validates the payload inside the
        // target context, so no separate validation pass is needed here.
        self.evaluate_dynamic_module(module.name, DynamicModuleEntry::Bytecode(module.bytes))
            .await
    }

    /// Declares a bytecode bundle and evaluates its entry module.
    ///
    /// The bundle entry must be present in `bundle.modules`. The return value is the module
    /// evaluation completion value, so import the entry afterwards if you need exported data.
    ///
    /// ## Example
    /// ```dart
    /// await engine.evaluateBytecodeBundle(bundle: pluginBundle);
    ///
    /// final result = await engine.eval(source: JsCode.code('''
    ///   const { default: plugin } = await import('plugins/main');
    ///   plugin.name
    /// '''));
    /// ```
    pub async fn evaluate_bytecode_bundle(
        &self,
        bundle: JsModuleBytecodeBundle,
    ) -> Result<JsValue, JsError> {
        self.ensure_running()?;
        validate_module_bundle_impl(&bundle)?;

        let Some(entry) = bundle.entry.clone() else {
            return Err(JsError::module(
                None,
                None,
                "Bytecode bundle has no entry module; declare it or provide an entry to evaluate",
            ));
        };

        let mut entry_module = None;
        let mut dependencies = Vec::new();
        for module in bundle.modules {
            if module.name == entry {
                entry_module = Some(module);
            } else {
                dependencies.push(module);
            }
        }

        let Some(entry_module) = entry_module else {
            return Err(JsError::module(
                Some(entry.clone()),
                None,
                format!("Bytecode bundle entry '{entry}' is not present in the bundle"),
            ));
        };

        if !dependencies.is_empty() {
            // Bundle validation above already covered these modules; declare
            // them directly instead of validating a second time.
            self.declare_dynamic_modules(
                dependencies
                    .into_iter()
                    .map(|module| (module.name, DynamicModuleEntry::Bytecode(module.bytes)))
                    .collect(),
            )
            .await?;
        }
        self.evaluate_bytecode_module(entry_module).await
    }

    /// Evaluates classic script bytecode in the current global context.
    ///
    /// This is the non-module counterpart to `evaluateBytecodeModule()`.
    ///
    /// Script bytecode may mutate global state and returns the script completion value,
    /// or the resolved value when compiled with top-level await support.
    ///
    /// ## Example
    /// ```dart
    /// final script = await JsBytecode.compileScript(
    ///   name: 'bootstrap.js',
    ///   source: JsCode.code('globalThis.appVersion = "3.0.0";'),
    /// );
    ///
    /// await engine.evaluateScriptBytecode(script: script);
    /// final version = await engine.eval(source: JsCode.code('globalThis.appVersion'));
    /// ```
    pub async fn evaluate_script_bytecode(
        &self,
        script: JsScriptBytecode,
    ) -> Result<JsValue, JsError> {
        let resources = self.ensure_running()?;
        validate_script_bytecode_impl(&script.name, &script.bytes)?;

        let script_name = script.name;
        let bytecode = script.bytes;
        let driver = resources.runtime.driver.clone();
        let shutdown = resources.runtime.shutdown();
        resources
            .context
            .with_foreground_js_result(async move |ctx, checkpoint| {
                let res = eval_script_bytecode(&ctx, &script_name, &bytecode);
                let driver = driver.clone();
                result_from_maybe_promise(&ctx, res, shutdown, move |source| {
                    driver.remove_error_source_since(checkpoint, source);
                })
                .await
            })
            .await
            .into_result()
    }

    /// Clears dynamic modules that have not been loaded into the QuickJS module cache.
    ///
    /// Dynamic modules become immutable for the lifetime of the context once they are loaded.
    /// This method only removes still-pending module registrations. Built-in modules and already
    /// loaded dynamic modules are not affected.
    ///
    /// ## Throws
    /// - If the engine is not initialized
    /// - If module storage is not available
    ///
    /// ## Example
    /// ```dart
    /// await engine.clearPendingModules();
    /// ```
    pub async fn clear_pending_modules(&self) -> Result<(), JsError> {
        self.ensure_running()?;

        let result = self
            .with_foreground_js_result(async |ctx, _checkpoint| {
                if let Some(storage) = ctx.userdata::<DynamicModuleStorage>() {
                    let loaded: HashSet<_> =
                        get_loaded_dynamic_module_names(&ctx).into_iter().collect();
                    storage
                        .write()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .retain(|name, _| loaded.contains(name));
                    JsResult::Ok(JsValue::None)
                } else {
                    JsResult::Err(JsError::storage("Module storage not initialized"))
                }
            })
            .await?;
        let _ = result;
        Ok(())
    }

    /// Gets all declared module names.
    ///
    /// Returns a list of all dynamically registered module names.
    ///
    /// ## Returns
    /// List of module names as strings
    ///
    /// ## Throws
    /// - If the engine is not initialized
    /// - If module storage is not available
    ///
    /// ## Example
    /// ```dart
    /// final modules = await engine.getDeclaredModules();
    /// print('Declared modules: $modules');
    /// ```
    pub async fn get_declared_modules(&self) -> Result<Vec<String>, JsError> {
        let resources = self.ensure_running()?;

        resources
            .context
            .with_js(async |ctx| {
                if let Some(storage) = ctx.userdata::<DynamicModuleStorage>() {
                    let mut modules: Vec<_> = storage
                        .read()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .keys()
                        .cloned()
                        .collect();
                    modules.sort();
                    Ok(modules)
                } else {
                    Err(JsError::storage("Module storage not initialized"))
                }
            })
            .await
    }

    /// Gets all modules available to this engine.
    ///
    /// Returns builtin modules, statically configured modules,
    /// and dynamically declared modules in a sorted list.
    ///
    /// ## Returns
    /// A sorted list of module specifiers that can currently be imported
    ///
    /// ## Throws
    /// - If the engine is not initialized
    /// - If collecting module names fails
    ///
    /// ## Example
    /// ```dart
    /// final modules = await engine.getAvailableModules();
    /// print(modules);
    /// ```
    pub async fn get_available_modules(&self) -> Result<Vec<String>, JsError> {
        let resources = self.ensure_running()?;
        resources.context.get_available_modules().await
    }

    /// Checks if a module is declared.
    ///
    /// ## Parameters
    /// - `moduleName`: The name of the module to check
    ///
    /// ## Returns
    /// `true` if the module exists, `false` otherwise
    ///
    /// ## Throws
    /// - If the engine is not initialized
    /// - If module storage is not available
    ///
    /// ## Example
    /// ```dart
    /// if (await engine.isModuleDeclared(moduleName: 'my-module')) {
    ///   print('Module exists!');
    /// }
    /// ```
    pub async fn is_module_declared(&self, module_name: String) -> Result<bool, JsError> {
        let resources = self.ensure_running()?;

        resources
            .context
            .with_js(async move |ctx| {
                if let Some(storage) = ctx.userdata::<DynamicModuleStorage>() {
                    Ok(storage
                        .read()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .contains_key(&module_name))
                } else {
                    Err(JsError::storage("Module storage not initialized"))
                }
            })
            .await
    }

    /// Checks if a module is available to the engine.
    ///
    /// This includes builtin modules, statically configured modules,
    /// and dynamically declared modules.
    ///
    /// ## Parameters
    /// - `moduleName`: The module name to check
    ///
    /// ## Returns
    /// `true` if the module can currently be imported, `false` otherwise
    ///
    /// ## Throws
    /// - If the engine is not initialized
    /// - If collecting module names fails
    ///
    /// ## Example
    /// ```dart
    /// final available = await engine.isModuleAvailable(moduleName: 'path');
    /// print(available);
    /// ```
    pub async fn is_module_available(&self, module_name: String) -> Result<bool, JsError> {
        self.ensure_running()?;
        Ok(self
            .get_available_modules()
            .await?
            .iter()
            .any(|name| name == &module_name))
    }

    /// Calls a function in a module.
    ///
    /// Imports the specified module and invokes one of its exported functions.
    ///
    /// ## Parameters
    /// - `module`: The module name to import
    /// - `method`: The function name to call (must be exported from the module)
    /// - `params`: Optional parameters to pass to the function
    ///
    /// ## Returns
    /// The result of the function call as a `JsValue`
    ///
    /// ## Throws
    /// - If the engine is not initialized
    /// - If the module cannot be imported
    /// - If the function does not exist
    /// - If the function call fails
    ///
    /// ## Example
    /// ```dart
    /// // Call a function with parameters
    /// final result = await engine.call(
    ///   module: 'math-utils',
    ///   method: 'add',
    ///   params: [JsValue.integer(1), JsValue.integer(2)],
    /// );
    /// print(result.value); // 3
    ///
    /// // Call a function without parameters
    /// final version = await engine.call(
    ///   module: 'config',
    ///   method: 'getVersion',
    /// );
    /// ```
    pub async fn call(
        &self,
        module: String,
        method: String,
        params: Option<Vec<JsValue>>,
    ) -> Result<JsValue, JsError> {
        let resources = self.ensure_running()?;

        let params = params.unwrap_or_default();
        let driver = resources.runtime.driver.clone();
        let shutdown = resources.runtime.shutdown();
        resources
            .context
            .with_foreground_js_result(async move |ctx, checkpoint| {
                let driver = driver.clone();
                call_module_method(&ctx, module, method, params, shutdown, move |source| {
                    driver.remove_error_source_since(checkpoint, source);
                })
                .await
            })
            .await
            .into_result()
    }
}

fn first_duplicate_name<'a>(names: impl IntoIterator<Item = &'a str>) -> Option<String> {
    let mut seen = HashSet::new();
    for name in names {
        if !seen.insert(name) {
            return Some(name.to_string());
        }
    }
    None
}

/// Registers the fjs bridge object.
fn register_fjs<'js>(
    ctx: rquickjs::Ctx<'js>,
    bridge: Arc<BridgeCallback>,
    shutdown: crate::runtime::shutdown::RuntimeShutdown,
) -> rquickjs::CaughtResult<'js, ()> {
    let fjs = Object::new(ctx.clone()).catch(&ctx)?;
    fjs.set(
        "bridge_call",
        new_bridge_call(ctx.clone(), bridge, shutdown)?,
    )
    .catch(&ctx)?;
    ctx.globals().set("fjs", fjs).catch(&ctx)?;
    Ok(())
}

/// Registers the cancellable fjs bridge object.
fn register_fjs_cancellable<'js>(
    ctx: rquickjs::Ctx<'js>,
    bridge: Arc<CancellableBridgeCallback>,
    cancel: Arc<BridgeCancelCallback>,
    shutdown: crate::runtime::shutdown::RuntimeShutdown,
) -> rquickjs::CaughtResult<'js, ()> {
    let fjs = Object::new(ctx.clone()).catch(&ctx)?;
    fjs.set(
        "bridge_call",
        new_cancellable_bridge_call(ctx.clone(), bridge, cancel, shutdown)?,
    )
    .catch(&ctx)?;
    ctx.globals().set("fjs", fjs).catch(&ctx)?;
    Ok(())
}

/// Creates the cancellable bridge_call function.
fn new_cancellable_bridge_call<'js>(
    ctx: rquickjs::Ctx<'js>,
    bridge: Arc<CancellableBridgeCallback>,
    cancel: Arc<BridgeCancelCallback>,
    shutdown: crate::runtime::shutdown::RuntimeShutdown,
) -> rquickjs::CaughtResult<'js, rquickjs::Function<'js>> {
    let ctx_for_catch = ctx.clone();
    let pending = Arc::new(Mutex::new(HashSet::<u64>::new()));
    rquickjs::Function::new(
        ctx,
        move |call_ctx: rquickjs::Ctx<'js>,
              args: rquickjs::function::Rest<rquickjs::Value<'js>>|
              -> rquickjs::Result<Promise<'js>> {
            if args.0.len() != 1 {
                return Err(rquickjs::Error::MissingArgs {
                    expected: 1,
                    given: args.len(),
                });
            }
            let value = JsValue::from_js(&call_ctx, args.0[0].clone())?;
            let id = NEXT_BRIDGE_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
            pending.lock().unwrap().insert(id);
            let pending_for_task = pending.clone();
            let bridge = bridge.clone();
            let cancel = cancel.clone();
            let shutdown = shutdown.clone();
            Promise::wrap_future(&call_ctx, async move {
                tokio::select! {
                    result = bridge(BridgeRequest { id, value, execution_id: None }) => {
                        pending_for_task.lock().unwrap().remove(&id);
                        match result {
                            JsResult::Ok(value) => Ok::<JsValue, rquickjs::Error>(value),
                            JsResult::Err(error) => Err(rquickjs::Error::new_from_js_message("bridge", "JsValue", error.to_string())),
                        }
                    }
                    _ = shutdown.cancelled() => {
                        pending_for_task.lock().unwrap().remove(&id);
                        let _ = cancel(id).await;
                        Err(rquickjs::Error::new_from_js_message("bridge", "JsValue", shutdown.error().to_string()))
                    }
                }
            })
        },
    )
    .catch(&ctx_for_catch)
}
/// Registers the two-stage fjs bridge.
fn register_fjs_broker<'js>(
    ctx: rquickjs::Ctx<'js>,
    start: Arc<BridgeStartCallback>,
    state: Arc<BrokerBridgeState>,
    shutdown: crate::runtime::shutdown::RuntimeShutdown,
) -> rquickjs::CaughtResult<'js, ()> {
    let fjs = Object::new(ctx.clone()).catch(&ctx)?;
    fjs.set(
        "bridge_call",
        new_broker_bridge_call(ctx.clone(), start, state, shutdown)?,
    )
    .catch(&ctx)?;
    ctx.globals().set("fjs", fjs).catch(&ctx)?;
    Ok(())
}

/// Creates a synchronous JS bridge backed by a Rust completion channel.
fn new_broker_bridge_call<'js>(
    ctx: rquickjs::Ctx<'js>,
    start: Arc<BridgeStartCallback>,
    state: Arc<BrokerBridgeState>,
    shutdown: crate::runtime::shutdown::RuntimeShutdown,
) -> rquickjs::CaughtResult<'js, rquickjs::Function<'js>> {
    let ctx_for_catch = ctx.clone();
    rquickjs::Function::new(ctx, move |call_ctx: rquickjs::Ctx<'js>, args: rquickjs::function::Rest<rquickjs::Value<'js>>| -> rquickjs::Result<JsValue> {
        if args.0.len() != 1 { return Err(rquickjs::Error::MissingArgs { expected: 1, given: args.len() }); }
        let value = JsValue::from_js(&call_ctx, args.0[0].clone())?;
        struct Depth<'a>(&'a AtomicU64);
        impl Drop for Depth<'_> {
            fn drop(&mut self) { self.0.fetch_sub(1, Ordering::Relaxed); }
        }
        let depth = state.depth.fetch_add(1, Ordering::Relaxed);
        let _depth = Depth(&state.depth);
        if depth >= 16 {
            return Err(rquickjs::Error::new_from_js_message("bridge", "JsValue", "Host nesting limit exceeded"));
        }
        let id = NEXT_BRIDGE_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        let (sender, mut receiver) = oneshot::channel();
        let (nested, mut commands) = mpsc::channel::<BrokerEval>(8);
        let (starter, registration) = AbortHandle::new_pair();
        let scope = state.active.lock().unwrap().last().cloned();
        let execution_id = scope.as_ref().map(|scope| scope.id);
        {
            let mut registry = broker_pending().lock().unwrap();
            if state.closed.load(Ordering::Acquire) || shutdown.requested() {
                return Err(rquickjs::Error::new_from_js_message("bridge", "JsValue", "engine closed"));
            }
            registry.insert(id, BrokerEntry { owner: state.owner, sender, starter, cancel: state.cancel.clone(), execution_id, nested, wake: state.wake.clone() });
        }
        let start = start.clone();
        let shutdown = shutdown.clone();
        let state = state.clone();
        #[cfg(windows)]
        if crate::runtime::fibers::active() {
            tokio::spawn(Abortable::new(async move {
                let result = AssertUnwindSafe(async { start(BridgeRequest { id, value, execution_id }).await }).catch_unwind().await;
                if result.is_err(){let _=complete_bridge_request_global(id,JsResult::Err(JsError::bridge("Host start callback failed")));}
            },registration));
            loop {
                if shutdown.requested() || state.closed.load(Ordering::Acquire) || scope.as_ref().is_some_and(|s|s.cancelled.load(Ordering::Acquire)) {
                    // The starter only acknowledges dispatch; let its FRB reply
                    // settle rather than aborting that reply during cancellation.
                    broker_pending().lock().unwrap().remove(&id);
                    return Err(rquickjs::Error::new_from_js_message("bridge","JsValue","Execution cancelled"));
                }
                match receiver.try_recv() {
                    Ok(JsResult::Ok(value))=>return Ok(value),
                    Ok(JsResult::Err(error))=>return Err(rquickjs::Error::new_from_js_message("bridge","JsValue",error.to_string())),
                    Err(oneshot::error::TryRecvError::Closed)=>return Err(rquickjs::Error::new_from_js_message("bridge","JsValue","Bridge request closed")),
                    Err(oneshot::error::TryRecvError::Empty)=>{},
                }
                if let Ok(command)=commands.try_recv(){
                    let result=call_ctx.eval::<rquickjs::Value,_>(command.source).and_then(|value|{
                        if value.is_promise(){return Err(rquickjs::Error::new_from_js_message("Promise","JsValue","Nested host evaluation must be synchronous"));}
                        JsValue::from_js(&call_ctx,value)
                    }).catch(&call_ctx).map_err(|error|JsError::from_caught(&call_ctx,error));
                    let result=if shutdown.requested(){Err(shutdown.error())}else{result};
                    let _=command.reply.send(result);
                    continue;
                }
                crate::runtime::fibers::suspend();
            }
        }
        tokio::task::block_in_place(|| tokio::runtime::Handle::current().block_on(async move {
            tokio::spawn(Abortable::new(async move {
                let result = AssertUnwindSafe(async { start(BridgeRequest { id, value, execution_id }).await })
                    .catch_unwind().await;
                if result.is_err() {
                    let _ = complete_bridge_request_global(id, JsResult::Err(JsError::bridge("Host start callback failed")));
                }
            }, registration));
            loop {
                if scope.as_ref().is_some_and(|s| s.cancelled.load(Ordering::Acquire)) {
                    if let Some(entry) = broker_pending().lock().unwrap().remove(&id) { entry.starter.abort(); }
                    return Err(rquickjs::Error::new_from_js_message("bridge", "JsValue", "Execution cancelled"));
                }
                tokio::select! {
                    biased;
                    _ = async { match &scope { Some(s) => s.wake.notified().await, None => std::future::pending::<()>().await } } => { continue; }
                    _ = state.wake.notified() => {
                        let command = {
                            let mut queue = state.executions.lock().unwrap();
                            let command = queue.commands.pop_front();
                            if !queue.commands.is_empty() { state.wake.notify_one(); }
                            command
                        };
                        if let Some(command) = command { run_scoped(&call_ctx, &state, command); }
                    }
                    _ = shutdown.cancelled() => {
                        return Err(rquickjs::Error::new_from_js_message("bridge", "JsValue", shutdown.error().to_string()));
                    }
                    result = &mut receiver => return match result {
                        Ok(JsResult::Ok(value)) => Ok(value),
                        Ok(JsResult::Err(error)) => Err(rquickjs::Error::new_from_js_message("bridge", "JsValue", error.to_string())),
                        Err(_) => Err(rquickjs::Error::new_from_js_message("bridge", "JsValue", "bridge request closed")),
                    },
                    Some(command) = commands.recv() => {
                        // Run on the suspended JS stack, never reacquire AsyncContext.
                        let result = call_ctx.eval::<rquickjs::Value, _>(command.source)
                            .and_then(|value| {
                                if value.is_promise() {
                                    return Err(rquickjs::Error::new_from_js_message("Promise", "JsValue", "Nested host evaluation must be synchronous"));
                                }
                                JsValue::from_js(&call_ctx, value)
                            })
                            .catch(&call_ctx)
                            .map_err(|error| JsError::from_caught(&call_ctx, error));
                        let result = if shutdown.requested() { Err(shutdown.error()) } else { result };
                        let _ = command.reply.send(result);
                    }
                }
            }
        }))
    }).catch(&ctx_for_catch)
}
/// Creates the bridge_call function.
fn new_bridge_call<'js>(
    ctx: rquickjs::Ctx<'js>,
    bridge: Arc<BridgeCallback>,
    shutdown: crate::runtime::shutdown::RuntimeShutdown,
) -> rquickjs::CaughtResult<'js, rquickjs::Function<'js>> {
    let ctx_for_catch = ctx.clone();
    rquickjs::Function::new(
        ctx.clone(),
        move |call_ctx: rquickjs::Ctx<'js>,
              args: rquickjs::function::Rest<rquickjs::Value<'js>>|
              -> rquickjs::Result<Promise<'js>> {
            if args.0.len() > 1 {
                return Err(rquickjs::Error::TooManyArgs {
                    expected: 1,
                    given: args.len(),
                });
            }
            if args.0.is_empty() {
                return Err(rquickjs::Error::MissingArgs {
                    expected: 1,
                    given: 0,
                });
            }

            let arg = args.0.first().ok_or(rquickjs::Error::MissingArgs {
                expected: 1,
                given: 0,
            })?;

            let js_value = JsValue::from_js(&call_ctx, arg.clone())?;
            let bridge_ref = bridge.clone();
            let shutdown = shutdown.clone();

            Promise::wrap_future(&call_ctx, async move {
                tokio::select! {
                    result = bridge_ref(js_value) => {
                        match result {
                            JsResult::Ok(value) => Ok::<JsValue, rquickjs::Error>(value),
                            JsResult::Err(err) => Err(rquickjs::Error::new_from_js_message(
                                "bridge",
                                "JsValue",
                                err.to_string(),
                            )),
                        }
                    }
                    _ = shutdown.cancelled() => Err(rquickjs::Error::new_from_js_message(
                        "bridge",
                        "JsValue",
                        shutdown.error().to_string(),
                    )),
                }
            })
        },
    )
    .catch(&ctx_for_catch)
}
