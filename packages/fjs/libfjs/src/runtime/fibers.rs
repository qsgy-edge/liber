//! Windows fibers stay on one OS thread while suspended Rust/C frames remain
//! live. Only the scheduler may resume them; every fiber must unwind before drop.
use rquickjs::qjs;
use std::{
    cell::Cell,
    ffi::c_void,
    marker::PhantomData,
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
    rc::Rc,
};

#[link(name = "kernel32")]
unsafe extern "system" {
    fn ConvertThreadToFiberEx(data: *mut c_void, flags: u32) -> *mut c_void;
    fn ConvertFiberToThread() -> i32;
    fn CreateFiberEx(
        commit: usize,
        reserve: usize,
        flags: u32,
        entry: unsafe extern "system" fn(*mut c_void),
        data: *mut c_void,
    ) -> *mut c_void;
    fn SwitchToFiber(fiber: *mut c_void);
    fn DeleteFiber(fiber: *mut c_void);
}
unsafe extern "C" {
    fn liber_stack_new() -> *mut c_void;
    fn liber_stack_capture(rt: *mut qjs::JSRuntime, state: *mut c_void);
    fn liber_stack_restore(rt: *mut qjs::JSRuntime, state: *mut c_void);
    fn liber_stack_free(rt: *mut qjs::JSRuntime, state: *mut c_void);
}
thread_local! { static CURRENT:Cell<*mut Control<'static>>=const {Cell::new(ptr::null_mut())}; }
struct Control<'a> {
    rt: *mut qjs::JSRuntime,
    snapshot: *mut c_void,
    parent: *mut c_void,
    work: Option<Box<dyn FnOnce() + 'a>>,
    done: bool,
    failed: bool,
}
pub(crate) struct Scheduler {
    parent: *mut c_void,
    snapshot: *mut c_void,
    rt: *mut qjs::JSRuntime,
    _same_thread: PhantomData<Rc<()>>,
}
impl Scheduler {
    pub(crate) unsafe fn new(rt: *mut qjs::JSRuntime) -> Result<Self, std::io::Error> {
        let snapshot = unsafe { liber_stack_new() };
        if snapshot.is_null() {
            return Err(std::io::Error::other("Cannot allocate stack state"));
        }
        let parent = unsafe { ConvertThreadToFiberEx(ptr::null_mut(), 1) };
        if parent.is_null() {
            unsafe { liber_stack_free(rt, snapshot) };
            return Err(std::io::Error::last_os_error());
        }
        Ok(Self {
            parent,
            snapshot,
            rt,
            _same_thread: PhantomData,
        })
    }
    pub(crate) fn create<'a>(&self, work: impl FnOnce() + 'a) -> Result<Fiber<'a>, std::io::Error> {
        let snapshot = unsafe { liber_stack_new() };
        if snapshot.is_null() {
            return Err(std::io::Error::other("Cannot allocate stack state"));
        }
        let mut control = Box::new(Control {
            rt: self.rt,
            snapshot,
            parent: self.parent,
            work: Some(Box::new(work)),
            done: false,
            failed: false,
        });
        let fiber = unsafe {
            CreateFiberEx(
                64 * 1024,
                super::executor::JS_THREAD_STACK_SIZE,
                1,
                enter,
                (&mut *control as *mut Control<'a>).cast(),
            )
        };
        if fiber.is_null() {
            unsafe { liber_stack_free(self.rt, snapshot) };
            return Err(std::io::Error::last_os_error());
        }
        Ok(Fiber {
            control: Box::into_raw(control),
            fiber,
            _same_thread: PhantomData,
        })
    }
    pub(crate) fn resume(&self, fiber: &mut Fiber<'_>) {
        assert!(!fiber.done());
        // The pointer never outlives this resume/suspend pair. Its erased
        // lifetime is used only to address Control's non-borrowing header.
        CURRENT.with(|slot| slot.set(fiber.control.cast()));
        unsafe {
            liber_stack_capture(self.rt, self.snapshot);
            liber_stack_restore(self.rt, (*fiber.control).snapshot);
            SwitchToFiber(fiber.fiber);
            liber_stack_restore(self.rt, self.snapshot);
        }
        CURRENT.with(|slot| slot.set(ptr::null_mut()));
    }
}
impl Drop for Scheduler {
    fn drop(&mut self) {
        unsafe {
            liber_stack_free(self.rt, self.snapshot);
            assert_ne!(ConvertFiberToThread(), 0);
        }
    }
}
pub(crate) struct Fiber<'a> {
    control: *mut Control<'a>,
    fiber: *mut c_void,
    _same_thread: PhantomData<Rc<()>>,
}
impl Fiber<'_> {
    pub(crate) fn done(&self) -> bool {
        unsafe { (*self.control).done }
    }
    pub(crate) fn failed(&self) -> bool {
        unsafe { (*self.control).failed }
    }
}
impl Drop for Fiber<'_> {
    fn drop(&mut self) {
        // Never free a stack containing suspended Rust values.
        assert!(self.done(), "Suspended execution dropped without unwinding");
        unsafe {
            DeleteFiber(self.fiber);
            let control = Box::from_raw(self.control);
            liber_stack_free(control.rt, control.snapshot);
        }
    }
}
unsafe extern "system" fn enter(data: *mut c_void) {
    let control = data.cast::<Control<'_>>();
    unsafe { qjs::JS_UpdateStackTop((*control).rt) };
    let work = unsafe { (*control).work.take().unwrap() };
    let failed = catch_unwind(AssertUnwindSafe(work)).is_err();
    unsafe {
        (*control).failed = failed;
        (*control).done = true;
    }
    suspend();
    std::process::abort();
}
pub(crate) fn active() -> bool {
    CURRENT.with(|slot| !slot.get().is_null())
}
pub(crate) fn suspend() {
    CURRENT.with(|slot| {
        let control = slot.get();
        assert!(!control.is_null());
        unsafe {
            liber_stack_capture((*control).rt, (*control).snapshot);
            SwitchToFiber((*control).parent);
        }
    });
}
