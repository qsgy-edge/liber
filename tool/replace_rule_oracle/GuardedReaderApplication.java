package io.liber.oracle.nested;

import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Refuses the selected reader's restart before it can launch the real app.
 *
 * <p>It also carries one bounded, opt-in capture guard for the approved
 * saved-content observation. The guard is inert unless {@link #arm} was called
 * for this process lifetime, so every other consumer keeps exactly the previous
 * behaviour: two activity-launch refusals and nothing else.
 *
 * <p>The guard is the single owner of the resources the selected saved-content
 * route creates: the exported {@code ACTION_LEB_IPC} receiver the LiveEventBus
 * singleton registers, the application lifecycle callback {@code AppUtils}
 * registers, and the per-case save-event observer. It accepts only the exact
 * registrations the inspected target actually performs, refuses everything else
 * before any platform effect, keeps a failed or uncertain handle visible until a
 * removal is proven, and never reports a closed domain while owned work can
 * still attach.
 */
public final class GuardedReaderApplication extends Application {
    private static final AtomicInteger attempts = new AtomicInteger();

    /** The exact action and receiver the selected LiveEventBus registers. */
    static final String LEB_IPC_ACTION = "intent.action.ACTION_LEB_IPC";
    static final String LEB_RECEIVER = "com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver";
    /** The exact lifecycle callback class AppUtils registers. */
    static final String LEB_LIFECYCLE = "com.jeremyliao.liveeventbus.utils.AppUtils$ActivityLifecycleImpl";
    /** The reference save event tag (EventBus.kt:32). */
    static final String SAVE_CONTENT_TAG = "saveContent";
    static final String OBSERVABLE_INTERFACE = "com.jeremyliao.liveeventbus.core.Observable";
    static final String OBSERVER_INTERFACE = "androidx.lifecycle.Observer";

    private static final Object lock = new Object();
    private static volatile GuardedReaderApplication owner;
    private static volatile ClassLoader targetLoader;
    private static volatile boolean armed;

    private static final Map<BroadcastReceiver, BroadcastReceiver> wrappers =
        new IdentityHashMap<>();
    private static final List<BroadcastReceiver> ownedReceivers = new ArrayList<>();
    private static final List<ActivityLifecycleCallbacks> ownedCallbacks = new ArrayList<>();
    private static final JSONArray receiverRegistrations = new JSONArray();
    private static final JSONArray receiverUnregistrations = new JSONArray();
    private static final JSONArray lifecycleRegistrations = new JSONArray();
    private static final JSONArray lifecycleUnregistrations = new JSONArray();
    private static final JSONArray inboundAttempts = new JSONArray();
    private static final JSONArray guardFailures = new JSONArray();
    private static final AtomicInteger blockedDeliveries = new AtomicInteger();
    private static final AtomicInteger foreignUnregistrations = new AtomicInteger();
    private static final AtomicInteger attemptedRegistrations = new AtomicInteger();
    private static final AtomicInteger successfulRegistrations = new AtomicInteger();

    private static volatile Object saveObservable;
    private static volatile Object saveObserver;
    private static volatile Method observeMethod;
    private static volatile Method removeMethod;
    private static volatile String expectBookUrl;
    private static volatile String expectChapterUrl;
    private static volatile boolean observing;
    private static volatile boolean observerClosed;
    private static volatile boolean captureFailed;
    private static volatile JSONObject lastEvent = new JSONObject();
    private static final AtomicInteger saveEvents = new AtomicInteger();
    private static final AtomicInteger foreignEvents = new AtomicInteger();
    private static final AtomicInteger callbackErrors = new AtomicInteger();

    /** Main-thread work this guard owns and has not yet seen finish. */
    private static final Map<Long, OwnedWork> pendingWork = new IdentityHashMap<>();
    private static final AtomicInteger workSequence = new AtomicInteger();

    /**
     * One queued main-thread work item. {@link #abandon()} makes a queued item
     * inert, so work the caller gave up on can never attach after closure.
     */
    private static final class OwnedWork {
        private final long id;
        private final Callable<JSONObject> body;
        private volatile boolean abandoned;
        private volatile boolean started;
        private volatile boolean finished;
        private volatile JSONObject result;
        private volatile Throwable failure;
        private final CountDownLatch done = new CountDownLatch(1);

        OwnedWork(long id, Callable<JSONObject> body) {
            this.id = id;
            this.body = body;
        }

        void abandon() { abandoned = true; }

        void run() {
            if (abandoned) {
                finished = true;
                done.countDown();
                return;
            }
            started = true;
            try {
                result = body.call();
            } catch (Throwable error) {
                failure = error;
            } finally {
                finished = true;
                done.countDown();
            }
        }
    }

    /** Constructing an instance never mutates an armed owner. */
    public GuardedReaderApplication() {}

    static int launchAttempts() { return attempts.get(); }

    /**
     * Arms the guard for this process lifetime with the exact owner and target
     * classloader the capture already proved. A second arm with a different
     * owner, a null owner or a null loader is refused.
     */
    public static void arm(Application application, ClassLoader loader) {
        if (!(application instanceof GuardedReaderApplication)) {
            throw new SecurityException("the capture guard needs its own application instance");
        }
        if (loader == null) {
            throw new SecurityException("the capture guard needs the verified target loader");
        }
        synchronized (lock) {
            if (armed && owner != null && owner != application) {
                throw new SecurityException("the capture guard is already armed for another owner");
            }
            if (armed && targetLoader != loader) {
                throw new SecurityException("the capture guard is already armed for another loader");
            }
            owner = (GuardedReaderApplication) application;
            targetLoader = loader;
            armed = true;
        }
    }

    static boolean isArmed() {
        synchronized (lock) {
            return armed;
        }
    }

    /** Whether the capture has recorded a failure that must fail the run. */
    public static boolean captureFailed() {
        return captureFailed;
    }

    private static void fail(String reason) {
        captureFailed = true;
        try {
            guardFailures.put(reason);
        } catch (Throwable ignored) {
            // The flag already records it.
        }
    }

    /** Answers whether this instance is the exact armed owner. */
    private boolean isOwner() {
        synchronized (lock) {
            return armed && owner == this;
        }
    }

    /**
     * Removes every process-owned resource once and answers whether the domain
     * is genuinely closed. A handle whose removal fails stays owned, so a retry
     * is a real retry and a failed removal is never turned into empty success.
     */
    public static JSONObject releaseProcessResources() {
        GuardedReaderApplication exactOwner;
        synchronized (lock) {
            exactOwner = owner;
        }
        JSONArray removalFailures = new JSONArray();
        int removedReceivers = 0;
        int removedCallbacks = 0;
        // The observer is a process resource too: process closure must not leave
        // it attached.
        JSONObject observerClose = new JSONObject();
        if (observing) {
            try {
                observerClose = exactOwner == null
                    ? new JSONObject().put("removed", false)
                    : exactOwner.closeObserver(0L);
            } catch (Throwable error) {
                try {
                    removalFailures.put("observer: " + error);
                } catch (Throwable ignored) {
                    // The failure is still counted below.
                }
            }
        }
        List<BroadcastReceiver> receivers;
        List<ActivityLifecycleCallbacks> callbacks;
        synchronized (lock) {
            receivers = new ArrayList<>(ownedReceivers);
            callbacks = new ArrayList<>(ownedCallbacks);
        }
        for (BroadcastReceiver wrapper : receivers) {
            try {
                if (exactOwner == null) throw new IllegalStateException("no exact owner");
                exactOwner.superUnregisterReceiver(wrapper);
                removedReceivers++;
                synchronized (lock) {
                    ownedReceivers.remove(wrapper);
                    wrappers.values().remove(wrapper);
                }
                receiverUnregistrations.put(wrapper.getClass().getName());
            } catch (Throwable error) {
                removalFailures.put("receiver: " + error);
                fail("receiver removal failed: " + error);
            }
        }
        for (ActivityLifecycleCallbacks callback : callbacks) {
            try {
                if (exactOwner == null) throw new IllegalStateException("no exact owner");
                exactOwner.superUnregisterCallbacks(callback);
                removedCallbacks++;
                synchronized (lock) {
                    ownedCallbacks.remove(callback);
                }
                lifecycleUnregistrations.put(callback.getClass().getName());
            } catch (Throwable error) {
                removalFailures.put("lifecycle: " + error);
                fail("lifecycle removal failed: " + error);
            }
        }
        int ownedReceiverCount;
        int ownedCallbackCount;
        int pending;
        synchronized (lock) {
            ownedReceiverCount = ownedReceivers.size();
            ownedCallbackCount = ownedCallbacks.size();
            pending = pendingWork.size();
        }
        JSONObject receipt = new JSONObject();
        try {
            receipt.put("ownedReceivers", receivers.size())
                .put("removedReceivers", removedReceivers)
                .put("ownedLifecycleCallbacks", callbacks.size())
                .put("removedLifecycleCallbacks", removedCallbacks)
                .put("removalFailures", removalFailures)
                .put("observerClose", observerClose)
                .put("remainingOwnedReceivers", ownedReceiverCount)
                .put("remainingOwnedLifecycleCallbacks", ownedCallbackCount)
                .put("pendingOwnedWork", pending)
                .put("closed", removalFailures.length() == 0
                    && ownedReceiverCount == 0
                    && ownedCallbackCount == 0
                    && pending == 0
                    && !observing);
        } catch (Throwable error) {
            return receipt;
        }
        return receipt;
    }

    /** The guard's own receipts; read once at the end of the lifetime. */
    public static JSONObject captureReceipt() throws Exception {
        JSONObject receipt = new JSONObject();
        synchronized (lock) {
            receipt.put("armed", armed)
                .put("ownerClass", owner == null ? JSONObject.NULL : owner.getClass().getName())
                .put("attemptedRegistrations", attemptedRegistrations.get())
                .put("successfulRegistrations", successfulRegistrations.get())
                .put("receiverRegistrations", new JSONArray(receiverRegistrations.toString()))
                .put("receiverUnregistrations", new JSONArray(receiverUnregistrations.toString()))
                .put("lifecycleRegistrations", new JSONArray(lifecycleRegistrations.toString()))
                .put("lifecycleUnregistrations", new JSONArray(lifecycleUnregistrations.toString()))
                .put("inboundAttempts", new JSONArray(inboundAttempts.toString()))
                .put("failures", new JSONArray(guardFailures.toString()))
                .put("blockedDeliveries", blockedDeliveries.get())
                .put("foreignUnregistrations", foreignUnregistrations.get())
                .put("pendingWrappers", wrappers.size())
                .put("pendingOwnedWork", pendingWork.size())
                .put("saveEvents", saveEvents.get())
                .put("foreignEvents", foreignEvents.get())
                .put("callbackErrors", callbackErrors.get())
                .put("observing", observing)
                .put("observerClosed", observerClosed)
                .put("captureFailed", captureFailed)
                .put("lastEvent", new JSONObject(lastEvent.toString()));
        }
        return receipt;
    }

    // --- per-case save-event observer -------------------------------------

    /**
     * Registers the save-event observer ON THE MAIN THREAD through the public
     * {@code Observable} interface, and acknowledges the executed call.
     */
    public static JSONObject beginSaveObservation(String bookUrl, String chapterUrl)
            throws Exception {
        final GuardedReaderApplication exactOwner;
        final ClassLoader loader;
        synchronized (lock) {
            if (!armed || owner == null) throw new IllegalStateException("the guard is not armed");
            exactOwner = owner;
            loader = targetLoader;
        }
        if (loader == null) throw new IllegalStateException("no target classloader");
        expectBookUrl = bookUrl;
        expectChapterUrl = chapterUrl;
        saveEvents.set(0);
        foreignEvents.set(0);
        callbackErrors.set(0);
        observerClosed = false;
        lastEvent = new JSONObject();
        return exactOwner.runOnMain(() -> {
            Class<?> observableInterface = loader.loadClass(OBSERVABLE_INTERFACE);
            Class<?> observerInterface = loader.loadClass(OBSERVER_INTERFACE);
            Class<?> pairClass = loader.loadClass("kotlin.Pair");
            Object observable = loader.loadClass("com.jeremyliao.liveeventbus.LiveEventBus")
                .getMethod("get", String.class, Class.class)
                .invoke(null, SAVE_CONTENT_TAG, pairClass);
            Method observe = observableInterface.getMethod("observeForever", observerInterface);
            Method remove = observableInterface.getMethod("removeObserver", observerInterface);
            Object observer = Proxy.newProxyInstance(loader,
                new Class<?>[]{observerInterface}, new SaveEventHandler());
            observe.invoke(observable, observer);
            saveObservable = observable;
            saveObserver = observer;
            observeMethod = observe;
            removeMethod = remove;
            observing = true;
            return new JSONObject()
                .put("tag", SAVE_CONTENT_TAG)
                .put("interface", OBSERVABLE_INTERFACE)
                .put("declaringClass", observe.getDeclaringClass().getName())
                .put("onMain", Looper.myLooper() == Looper.getMainLooper())
                .put("registered", true);
        });
    }

    /**
     * Waits for this case's correlated save event, then removes the observer on
     * the main thread and acknowledges that executed call. A second call after a
     * successful end is an idempotent no-op; a call after a failed or abandoned
     * registration still closes whatever the guard owns.
     */
    public static JSONObject endSaveObservation(long timeoutMillis) throws Exception {
        GuardedReaderApplication exactOwner;
        synchronized (lock) {
            exactOwner = owner;
        }
        if (exactOwner == null) throw new IllegalStateException("the guard is not armed");
        return exactOwner.closeObserver(timeoutMillis);
    }

    private JSONObject closeObserver(long timeoutMillis) throws Exception {
        JSONObject result = new JSONObject();
        if (observerClosed && !observing) {
            // Already closed by a previous end or by process release.
            return result.put("alreadyClosed", true).put("removed", true)
                .put("events", saveEvents.get());
        }
        long deadline = System.currentTimeMillis() + timeoutMillis;
        while (saveEvents.get() == 0 && System.currentTimeMillis() < deadline) {
            Thread.sleep(5);
        }
        JSONObject removal = runOnMain(() -> {
            Object observable = saveObservable;
            Object observer = saveObserver;
            Method remove = removeMethod;
            if (observable == null || observer == null || remove == null) {
                // A registration that never completed owns nothing to remove.
                observing = false;
                observerClosed = true;
                return new JSONObject().put("removed", false).put("reason", "never-registered");
            }
            remove.invoke(observable, observer);
            observing = false;
            observerClosed = true;
            saveObservable = null;
            saveObserver = null;
            return new JSONObject()
                .put("interface", OBSERVABLE_INTERFACE)
                .put("declaringClass", remove.getDeclaringClass().getName())
                .put("onMain", Looper.myLooper() == Looper.getMainLooper())
                .put("removed", true);
        });
        // The final actual case facts are snapshotted after the removal ack.
        result.put("events", saveEvents.get())
            .put("foreignEvents", foreignEvents.get())
            .put("callbackErrors", callbackErrors.get())
            .put("lastEvent", new JSONObject(lastEvent.toString()))
            .put("removal", removal);
        if (foreignEvents.get() != 0) {
            fail("a foreign or duplicate save event reached this case's observer");
            result.put("failed", true);
        }
        if (callbackErrors.get() != 0) {
            fail("a save-event callback failed");
            result.put("failed", true);
        }
        return result;
    }

    /** The proxy that records what the save event actually delivered. */
    private static final class SaveEventHandler implements InvocationHandler {
        @Override public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            switch (method.getName()) {
                case "onChanged":
                    try {
                        Object value = args == null || args.length == 0 ? null : args[0];
                        String bookUrl = null;
                        String chapterUrl = null;
                        if (value != null) {
                            Object first = value.getClass().getMethod("getFirst").invoke(value);
                            Object second = value.getClass().getMethod("getSecond").invoke(value);
                            bookUrl = first == null ? null
                                : (String) first.getClass().getMethod("getBookUrl").invoke(first);
                            chapterUrl = second == null ? null
                                : (String) second.getClass().getMethod("getUrl").invoke(second);
                        }
                        boolean correlates = bookUrl != null && chapterUrl != null
                            && bookUrl.equals(expectBookUrl) && chapterUrl.equals(expectChapterUrl);
                        if (correlates) saveEvents.incrementAndGet();
                        else foreignEvents.incrementAndGet();
                        synchronized (GuardedReaderApplication.class) {
                            lastEvent = new JSONObject()
                                .put("bookUrl", bookUrl == null ? JSONObject.NULL : bookUrl)
                                .put("chapterUrl", chapterUrl == null ? JSONObject.NULL : chapterUrl)
                                .put("correlates", correlates);
                        }
                    } catch (Throwable error) {
                        callbackErrors.incrementAndGet();
                        fail("save callback failed: " + error);
                    }
                    return null;
                case "toString":
                    return "fields-save-observer";
                case "hashCode":
                    return System.identityHashCode(proxy);
                case "equals":
                    return args != null && args.length == 1 && proxy == args[0];
                default:
                    return null;
            }
        }
    }

    /**
     * Runs one callable on the main thread and returns its actual result.
     *
     * <p>The queued item is owned: if the caller times out or is interrupted, the
     * item is marked abandoned so it can never run after the caller gave up, and
     * it stays counted as pending until the main thread has actually seen it.
     */
    private JSONObject runOnMain(Callable<JSONObject> work) throws Exception {
        if (Looper.myLooper() == Looper.getMainLooper()) return work.call();
        final long id = workSequence.incrementAndGet();
        final OwnedWork owned = new OwnedWork(id, work);
        synchronized (lock) {
            pendingWork.put(id, owned);
        }
        boolean posted = new Handler(Looper.getMainLooper()).post(owned::run);
        if (!posted) {
            synchronized (lock) {
                pendingWork.remove(id);
            }
            throw new IllegalStateException("the main looper refused the work");
        }
        boolean completed;
        try {
            completed = owned.done.await(30000, TimeUnit.MILLISECONDS);
        } catch (InterruptedException interrupted) {
            owned.abandon();
            Thread.currentThread().interrupt();
            throw interrupted;
        }
        if (!completed) {
            owned.abandon();
            throw new IllegalStateException("main-thread work did not complete");
        }
        synchronized (lock) {
            pendingWork.remove(id);
        }
        if (owned.failure != null) {
            throw owned.failure instanceof Exception
                ? (Exception) owned.failure : new IllegalStateException(owned.failure);
        }
        return owned.result instanceof JSONObject ? owned.result : new JSONObject();
    }

    /** Posts a marker to the main looper and waits for it. */
    public static JSONObject fenceMainLooper(long timeoutMillis) throws Exception {
        final CountDownLatch latch = new CountDownLatch(1);
        boolean posted = new Handler(Looper.getMainLooper()).post(latch::countDown);
        boolean completed = posted && latch.await(timeoutMillis, TimeUnit.MILLISECONDS);
        return new JSONObject()
            .put("posted", posted)
            .put("completed", completed)
            .put("timeoutMillis", timeoutMillis)
            .put("mainThread", Looper.myLooper() == Looper.getMainLooper());
    }

    // --- activity refusals (always on) ------------------------------------

    @Override public void startActivity(Intent intent) {
        attempts.incrementAndGet();
        throw new SecurityException("selected reader refused activity launch");
    }

    @Override public void startActivity(Intent intent, Bundle options) {
        attempts.incrementAndGet();
        throw new SecurityException("selected reader refused activity launch");
    }

    // --- receiver / lifecycle ownership -----------------------------------

    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter) {
        if (!isArmed()) return super.registerReceiver(receiver, filter);
        // The approved route is only the inspected three-argument flags-2 form.
        attemptedRegistrations.incrementAndGet();
        fail("the two-argument registerReceiver overload is not the inspected route");
        throw new SecurityException(
            "guarded capture refuses the two-argument registerReceiver overload");
    }

    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter, int flags) {
        if (!isArmed()) return super.registerReceiver(receiver, filter, flags);
        if (!isOwner()) {
            throw new SecurityException("this instance is not the armed capture owner");
        }
        return guardRegister(receiver, filter, flags, "3-arg");
    }

    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter,
            String broadcastPermission, android.os.Handler scheduler) {
        if (!isArmed()) {
            return super.registerReceiver(receiver, filter, broadcastPermission, scheduler);
        }
        return refuseOverload("4-arg", receiver, filter);
    }

    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter,
            String broadcastPermission, android.os.Handler scheduler, int flags) {
        if (!isArmed()) {
            return super.registerReceiver(receiver, filter, broadcastPermission, scheduler, flags);
        }
        return refuseOverload("5-arg", receiver, filter);
    }

    private Intent guardRegister(BroadcastReceiver receiver, IntentFilter filter, int flags,
            String overload) {
        attemptedRegistrations.incrementAndGet();
        String rejection = rejectionOf(receiver, filter, flags, overload);
        if (rejection != null) {
            fail(rejection);
            throw new SecurityException("guarded capture refused: " + rejection);
        }
        synchronized (lock) {
            if (wrappers.containsKey(receiver)) {
                fail("duplicate registration of the same receiver");
                throw new SecurityException("guarded capture refused a duplicate registration");
            }
        }
        BroadcastReceiver wrapper = new GuardedReceiver(receiver);
        Intent sticky;
        try {
            sticky = super.registerReceiver(wrapper, filter, flags);
        } catch (Throwable error) {
            fail("registration failed: " + error);
            throw error instanceof SecurityException ? (SecurityException) error
                : new SecurityException("guarded registration failed: " + error, error);
        }
        successfulRegistrations.incrementAndGet();
        synchronized (lock) {
            wrappers.put(receiver, wrapper);
            ownedReceivers.add(wrapper);
            try {
                receiverRegistrations.put(new JSONObject()
                    .put("overload", overload)
                    .put("nativeClass", receiver.getClass().getName())
                    .put("wrapperClass", wrapper.getClass().getName())
                    .put("flags", flags)
                    .put("actions", actionsOf(filter))
                    .put("registered", true));
            } catch (Throwable ignored) {
                // The successful platform return already happened.
            }
        }
        return sticky;
    }

    /** The exact registration this capture allows, or the reason it is refused. */
    private static String rejectionOf(BroadcastReceiver receiver, IntentFilter filter,
            int flags, String overload) {
        if (receiver == null || filter == null) return "registration without a receiver or filter";
        if (!LEB_RECEIVER.equals(receiver.getClass().getName())) {
            return "unexpected receiver class " + receiver.getClass().getName();
        }
        JSONArray actions = actionsOf(filter);
        if (actions.length() != 1 || !LEB_IPC_ACTION.equals(actions.optString(0))) {
            return "unexpected filter actions " + actions;
        }
        if (filter.countDataTypes() != 0 || filter.countDataSchemes() != 0
                || filter.countCategories() != 0) {
            return "unexpected filter data or categories";
        }
        if (!"3-arg".equals(overload) || flags != 2) {
            return "unexpected registration overload or flags " + overload + "/" + flags;
        }
        return null;
    }

    private Intent refuseOverload(String overload, BroadcastReceiver receiver, IntentFilter filter) {
        fail("unexpected registration overload " + overload + " for "
            + (receiver == null ? "null" : receiver.getClass().getName())
            + " actions=" + actionsOf(filter));
        throw new SecurityException("guarded capture refuses the " + overload
            + " registerReceiver overload");
    }

    @Override
    public void unregisterReceiver(BroadcastReceiver receiver) {
        if (!isArmed()) {
            super.unregisterReceiver(receiver);
            return;
        }
        BroadcastReceiver wrapper;
        synchronized (lock) {
            wrapper = wrappers.get(receiver);
        }
        if (wrapper == null) {
            // Refused BEFORE any delegate effect: a foreign unregistration must
            // never reach the platform.
            foreignUnregistrations.incrementAndGet();
            fail("unregister of a receiver the guard does not own: "
                + (receiver == null ? "null" : receiver.getClass().getName()));
            throw new SecurityException("guarded capture refuses a foreign unregistration");
        }
        super.unregisterReceiver(wrapper);
        synchronized (lock) {
            wrappers.remove(receiver);
            ownedReceivers.remove(wrapper);
        }
        try {
            receiverUnregistrations.put(wrapper.getClass().getName());
        } catch (Throwable ignored) {
            // The successful platform return already happened.
        }
    }

    @Override
    public void registerActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
        if (!isArmed()) {
            super.registerActivityLifecycleCallbacks(callback);
            return;
        }
        if (!isOwner()) {
            throw new SecurityException("this instance is not the armed capture owner");
        }
        attemptedRegistrations.incrementAndGet();
        if (callback == null || !LEB_LIFECYCLE.equals(callback.getClass().getName())) {
            fail("unexpected lifecycle callback "
                + (callback == null ? "null" : callback.getClass().getName()));
            throw new SecurityException("guarded capture refused an unexpected lifecycle callback");
        }
        super.registerActivityLifecycleCallbacks(callback);
        successfulRegistrations.incrementAndGet();
        synchronized (lock) {
            ownedCallbacks.add(callback);
            try {
                lifecycleRegistrations.put(callback.getClass().getName());
            } catch (Throwable ignored) {
                // The successful platform return already happened.
            }
        }
    }

    @Override
    public void unregisterActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
        if (!isArmed()) {
            super.unregisterActivityLifecycleCallbacks(callback);
            return;
        }
        synchronized (lock) {
            if (!ownedCallbacks.contains(callback)) {
                foreignUnregistrations.incrementAndGet();
                fail("unregister of a lifecycle callback the guard does not own");
                throw new SecurityException(
                    "guarded capture refuses a foreign lifecycle unregistration");
            }
        }
        super.unregisterActivityLifecycleCallbacks(callback);
        synchronized (lock) {
            ownedCallbacks.remove(callback);
        }
        try {
            lifecycleUnregistrations.put(
                callback == null ? "null" : callback.getClass().getName());
        } catch (Throwable ignored) {
            // The successful platform return already happened.
        }
    }

    private void superUnregisterReceiver(BroadcastReceiver wrapper) {
        super.unregisterReceiver(wrapper);
    }

    private void superUnregisterCallbacks(ActivityLifecycleCallbacks callback) {
        super.unregisterActivityLifecycleCallbacks(callback);
    }

    private static JSONArray actionsOf(IntentFilter filter) {
        JSONArray actions = new JSONArray();
        if (filter == null) return actions;
        java.util.Iterator<String> declared = filter.actionsIterator();
        while (declared != null && declared.hasNext()) actions.put(declared.next());
        return actions;
    }

    /**
     * The wrapper the guard registers in place of the native receiver. It never
     * delivers to the native receiver and never inspects the intent's extras: an
     * inbound IPC attempt is a capture failure, not a silently contained success.
     */
    private static final class GuardedReceiver extends BroadcastReceiver {
        private final BroadcastReceiver delegate;

        GuardedReceiver(BroadcastReceiver delegate) { this.delegate = delegate; }

        @Override public void onReceive(Context context, Intent intent) {
            blockedDeliveries.incrementAndGet();
            fail("an inbound IPC attempt reached the guarded receiver");
            synchronized (lock) {
                try {
                    inboundAttempts.put(new JSONObject()
                        .put("action", intent == null ? JSONObject.NULL : intent.getAction())
                        .put("nativeClass", delegate.getClass().getName()));
                } catch (Throwable ignored) {
                    // The blocked delivery is still counted.
                }
            }
        }
    }
}
