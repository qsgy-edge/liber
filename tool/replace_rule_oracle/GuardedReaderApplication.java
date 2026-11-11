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

    /** Set once by the first armed final release; never cleared. */
    private static volatile boolean closing;

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
    private static volatile boolean observing;
    private static volatile boolean observerClosed;
    private static volatile boolean captureFailed;
    private static volatile JSONObject lastEvent = new JSONObject();

    /**
     * One owned save observation. Every proxy is bound to its own instance, so a
     * retained callback from an earlier case can never be counted in a later one.
     */
    private static final class Observation {
        final String bookUrl;
        final String chapterUrl;
        final AtomicInteger events = new AtomicInteger();
        final AtomicInteger duplicates = new AtomicInteger();
        final AtomicInteger foreign = new AtomicInteger();
        final AtomicInteger callbackErrors = new AtomicInteger();
        final AtomicInteger offMain = new AtomicInteger();
        final AtomicInteger malformed = new AtomicInteger();
        volatile JSONObject lastEvent = new JSONObject();
        volatile boolean closed;

        Observation(String bookUrl, String chapterUrl) {
            this.bookUrl = bookUrl;
            this.chapterUrl = chapterUrl;
        }

        /** The final validity of this observation, snapshot after real removal. */
        boolean valid() {
            return events.get() == 1 && duplicates.get() == 0 && foreign.get() == 0
                && callbackErrors.get() == 0 && offMain.get() == 0 && malformed.get() == 0;
        }
    }

    /** The live observation, or null when none is pending. */
    private static volatile Observation current;

    /** The frozen terminal view of the last acknowledged close, if any. */
    private static volatile JSONObject lastTerminal;

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
        // The cheap existing-lock rejection runs FIRST, so an already-known
        // closed or differently-owned lifetime never consults a supplied loader.
        synchronized (lock) {
            if (!(application instanceof GuardedReaderApplication)) {
                if (armed || closing) fail("arm with an invalid application argument");
                throw new SecurityException("the capture guard needs its own application instance");
            }
            if (loader == null) {
                if (armed || closing) fail("arm with a null loader argument");
                throw new SecurityException("the capture guard needs the verified target loader");
            }
            if (closing) {
                fail("arm after the process closing boundary");
                throw new SecurityException(
                    "the capture guard lifetime is closed; no new arm is admitted");
            }
            if (armed && owner != null && owner != application) {
                fail("arm for another owner while the guard is already armed");
                throw new SecurityException("the capture guard is already armed for another owner");
            }
            if (armed && targetLoader != loader) {
                fail("arm with another loader while the guard is already armed");
                throw new SecurityException("the capture guard is already armed for another loader");
            }
            if (armed) {
                // The same open owner and loader is idempotent: no resolver work
                // and no reset of handles, counters or failure state.
                return;
            }
        }
        // A not-yet-armed candidate validates the required shapes OUTSIDE the
        // global lock, without initializing any class.
        Throwable unready = readinessOf(loader);
        if (unready != null) {
            fail("arm with an unready loader: " + stackTraceOf(unready));
            throw unready instanceof SecurityException ? (SecurityException) unready
                : new SecurityException(
                    "the capture guard needs a loader that resolves its registration classes",
                    unready);
        }
        synchronized (lock) {
            // Recheck identity and closing immediately before publication.
            if (closing) {
                fail("arm after the process closing boundary");
                throw new SecurityException(
                    "the capture guard lifetime is closed; no new arm is admitted");
            }
            if (armed) {
                if (owner != application) {
                    fail("arm for another owner while the guard is already armed");
                    throw new SecurityException(
                        "the capture guard is already armed for another owner");
                }
                if (targetLoader != loader) {
                    fail("arm with another loader while the guard is already armed");
                    throw new SecurityException(
                        "the capture guard is already armed for another loader");
                }
                return;
            }
            owner = (GuardedReaderApplication) application;
            targetLoader = loader;
            armed = true;
        }
    }

    /**
     * The required registration shapes, or the original failure to resolve them.
     *
     * <p>Classes are resolved without initialization and no access bypass is
     * used. A null answer means ready. The returned throwable is the real
     * expected reflection, linkage or security failure with its own cause and
     * suppressed graph intact.
     */
    private static Throwable readinessOf(ClassLoader loader) {
        try {
            Class<?> receiver = Class.forName(LEB_RECEIVER, false, loader);
            if (!BroadcastReceiver.class.isAssignableFrom(receiver)) {
                return new SecurityException("the receiver is not a BroadcastReceiver");
            }
            Class<?> lifecycle = Class.forName(LEB_LIFECYCLE, false, loader);
            if (!ActivityLifecycleCallbacks.class.isAssignableFrom(lifecycle)) {
                return new SecurityException(
                    "the lifecycle callback is not an ActivityLifecycleCallbacks");
            }
            Class<?> observable = Class.forName(OBSERVABLE_INTERFACE, false, loader);
            if (!observable.isInterface()
                    || !java.lang.reflect.Modifier.isPublic(observable.getModifiers())) {
                return new SecurityException(
                    "the observable seam is not a public interface");
            }
            Class<?> observer = Class.forName(OBSERVER_INTERFACE, false, loader);
            if (!observer.isInterface()
                    || !java.lang.reflect.Modifier.isPublic(observer.getModifiers())) {
                return new SecurityException("the observer seam is not a public interface");
            }
            return null;
        } catch (Throwable error) {
            // The original instance is preserved, never flattened to a string.
            return error;
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

    /** Whether the armed lifetime has crossed its final closing boundary. */
    private static boolean isClosing() {
        synchronized (lock) {
            return closing;
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
            // The first armed release establishes final closing before any
            // snapshot, so no new acquisition can slip in behind it.
            if (armed) closing = true;
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
                    // The complete throwable graph, and the capture failure is
                    // marked while receiver and lifecycle cleanup still run.
                    String chain = stackTraceOf(error);
                    removalFailures.put("observer: " + chain);
                    fail("observer removal failed: " + chain);
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
                // The complete throwable graph, so a nested or suppressed cause
                // in the final release is never lost.
                String chain = stackTraceOf(error);
                removalFailures.put("receiver: " + chain);
                fail("receiver removal failed: " + chain);
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
                // The complete throwable graph, so a nested or suppressed cause
                // in the final lifecycle cleanup is never lost.
                String chain = stackTraceOf(error);
                removalFailures.put("lifecycle: " + chain);
                fail("lifecycle removal failed: " + chain);
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
            Observation live = current;
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
                .put("saveEvents", live == null ? 0 : live.events.get())
                .put("foreignEvents", live == null ? 0 : live.foreign.get())
                .put("callbackErrors", live == null ? 0 : live.callbackErrors.get())
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
        // An overlapping or pending observation is refused BEFORE any counter,
        // identity or live observer is reset.
        final Observation observation;
        synchronized (lock) {
            if (closing) {
                fail("observation after the process closing boundary");
                throw new SecurityException(
                    "the capture guard lifetime is closed; no new observation is admitted");
            }
            if (current != null && !current.closed) {
                throw new IllegalStateException(
                    "a save observation is already pending for another case");
            }
            observation = new Observation(bookUrl, chapterUrl);
            current = observation;
            observerClosed = false;
        }
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
                new Class<?>[]{observerInterface}, new SaveEventHandler(observation, loader));
            // The complete removal tuple is reserved BEFORE the effect, so a
            // throwing observeForever cannot lose the handle it may have installed.
            saveObservable = observable;
            saveObserver = observer;
            observeMethod = observe;
            removeMethod = remove;
            observing = true;
            try {
                observe.invoke(observable, observer);
            } catch (Throwable error) {
                fail("observer registration failed: " + stackTraceOf(error));
                throw error instanceof Exception ? (Exception) error
                    : new IllegalStateException(error);
            }
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
        final Observation observation = current;
        if (observerClosed && !observing) {
            // A repeat returns the frozen terminal snapshot of the first close.
            // Only an acknowledged actual removal can be an idempotent success; a
            // never-registered close stays a failed non-removal on every repeat.
            JSONObject terminal = lastTerminal;
            if (terminal == null) {
                return result.put("alreadyClosed", true).put("removed", false)
                    .put("reason", "never-registered").put("failed", true);
            }
            result.put("alreadyClosed", true);
            // A deep copy, so a caller editing any returned root or nested object
            // cannot mutate the cached first-close facts.
            JSONObject copy = new JSONObject(terminal.toString());
            java.util.Iterator<String> names = copy.keys();
            while (names.hasNext()) {
                String name = names.next();
                result.put(name, copy.get(name));
            }
            // The top-level acknowledgement mirrors the actual removal that was
            // really observed on the first close, never an invented one.
            JSONObject recorded = terminal.optJSONObject("removal");
            boolean acknowledged = recorded != null && recorded.optBoolean("removed");
            result.put("removed", acknowledged);
            if (!acknowledged) result.put("failed", true);
            return result;
        }
        long deadline = System.currentTimeMillis() + timeoutMillis;
        while ((observation == null || observation.events.get() == 0)
                && System.currentTimeMillis() < deadline) {
            Thread.sleep(5);
        }
        JSONObject removal = runOnMain(() -> {
            Object observable = saveObservable;
            Object observer = saveObserver;
            Method remove = removeMethod;
            if (observable == null || observer == null || remove == null) {
                // A registration that never completed owns nothing to remove, so
                // there is no acknowledgement to repeat as a success.
                observing = false;
                observerClosed = true;
                lastTerminal = null;
                return new JSONObject().put("removed", false).put("reason", "never-registered");
            }
            try {
                remove.invoke(observable, observer);
            } catch (Throwable error) {
                // The tuple stays owned: without an acknowledgement the removal is
                // uncertain, and the complete cause is retained.
                fail("observer removal failed: " + stackTraceOf(error));
                throw error instanceof Exception ? (Exception) error
                    : new IllegalStateException(error);
            }
            observing = false;
            observerClosed = true;
            if (observation != null) observation.closed = true;
            saveObservable = null;
            saveObserver = null;
            return new JSONObject()
                .put("interface", OBSERVABLE_INTERFACE)
                .put("declaringClass", remove.getDeclaringClass().getName())
                .put("onMain", Looper.myLooper() == Looper.getMainLooper())
                .put("removed", true);
        });
        // The final actual case facts are snapshotted after the removal ack, from
        // this observation's own counters.
        int events = observation == null ? 0 : observation.events.get();
        int duplicates = observation == null ? 0 : observation.duplicates.get();
        int foreign = observation == null ? 0 : observation.foreign.get();
        int callbackErrors = observation == null ? 0 : observation.callbackErrors.get();
        int offMain = observation == null ? 0 : observation.offMain.get();
        int malformed = observation == null ? 0 : observation.malformed.get();
        result.put("events", events)
            .put("duplicates", duplicates)
            .put("foreignEvents", foreign)
            .put("callbackErrors", callbackErrors)
            .put("offMainEvents", offMain)
            .put("malformedEvents", malformed)
            .put("lastEvent", new JSONObject(
                (observation == null ? lastEvent : observation.lastEvent).toString()))
            .put("removal", removal);
        if (duplicates != 0) {
            fail("a duplicate save event reached this case's observer");
            result.put("failed", true);
        }
        if (foreign != 0) {
            fail("a foreign save event reached this case's observer");
            result.put("failed", true);
        }
        if (callbackErrors != 0) {
            fail("a save-event callback failed");
            result.put("failed", true);
        }
        if (offMain != 0) {
            fail("a save event was delivered off the main thread");
            result.put("failed", true);
        }
        if (malformed != 0) {
            fail("a malformed save event reached this case's observer");
            result.put("failed", true);
        }
        if (events != 1) {
            fail("the case observation did not carry exactly one correlated save event");
            result.put("failed", true);
        }
        // Freeze the terminal view only after every fact is known, so a later
        // stale callback or a repeat cannot change what this case reports.
        lastTerminal = removal.optBoolean("removed")
            ? new JSONObject(result.toString()) : null;
        return result;
    }

    /** The complete throwable graph, including the reflection target and causes. */
    private static String stackTraceOf(Throwable error) {
        java.io.StringWriter text = new java.io.StringWriter();
        java.io.PrintWriter writer = new java.io.PrintWriter(text);
        error.printStackTrace(writer);
        writer.flush();
        return text.toString();
    }

    /**
     * The proxy that records what the save event actually delivered.
     *
     * <p>It is bound to its own observation, so a retained callback from an
     * earlier case cannot be counted in a later one. The payload type identities
     * are checked against the verified loader before any payload method runs, so
     * a duck-typed impostor's getter is never executed.
     */
    private static final class SaveEventHandler implements InvocationHandler {
        private final Observation observation;
        private final ClassLoader loader;

        SaveEventHandler(Observation observation, ClassLoader loader) {
            this.observation = observation;
            this.loader = loader;
        }

        @Override public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            switch (method.getName()) {
                case "onChanged":
                    if (Looper.myLooper() != Looper.getMainLooper()) {
                        observation.offMain.incrementAndGet();
                        fail("a save event was delivered off the main thread");
                        return null;
                    }
                    if (observation.closed) {
                        // A retained callback whose observation already closed is
                        // stale: it fails the capture and is never counted.
                        observation.foreign.incrementAndGet();
                        fail("a stale save-event callback ran after its observation closed");
                        return null;
                    }
                    try {
                        Object value = args == null || args.length == 0 ? null : args[0];
                        Class<?> pairClass = loader.loadClass("kotlin.Pair");
                        Class<?> bookClass = loader.loadClass(
                            "io.legado.app.data.entities.Book");
                        Class<?> chapterClass = loader.loadClass(
                            "io.legado.app.data.entities.BookChapter");
                        // Type identity first: an impostor's getters never run.
                        if (value == null || !pairClass.isInstance(value)) {
                            observation.malformed.incrementAndGet();
                            fail("the save event payload is not the approved Pair type");
                            return null;
                        }
                        Object first = pairClass.getMethod("getFirst").invoke(value);
                        Object second = pairClass.getMethod("getSecond").invoke(value);
                        if (first == null || !bookClass.isInstance(first)
                                || second == null || !chapterClass.isInstance(second)) {
                            observation.malformed.incrementAndGet();
                            fail("the save event pair does not carry the approved Book and"
                                + " BookChapter types");
                            return null;
                        }
                        String bookUrl = (String) bookClass.getMethod("getBookUrl").invoke(first);
                        String chapterUrl = (String) chapterClass.getMethod("getUrl")
                            .invoke(second);
                        boolean correlates = bookUrl != null && chapterUrl != null
                            && bookUrl.equals(observation.bookUrl)
                            && chapterUrl.equals(observation.chapterUrl);
                        if (!correlates) {
                            observation.foreign.incrementAndGet();
                        } else if (observation.events.get() == 0) {
                            observation.events.incrementAndGet();
                        } else {
                            observation.duplicates.incrementAndGet();
                        }
                        JSONObject event = new JSONObject()
                            .put("bookUrl", bookUrl == null ? JSONObject.NULL : bookUrl)
                            .put("chapterUrl", chapterUrl == null ? JSONObject.NULL : chapterUrl)
                            .put("correlates", correlates);
                        observation.lastEvent = event;
                        lastEvent = event;
                    } catch (Throwable error) {
                        observation.callbackErrors.incrementAndGet();
                        // The reflective wrapper's toString omits its target, so
                        // the complete throwable graph is retained instead.
                        fail("save callback failed: " + stackTraceOf(error));
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
            fail("receiver registration by a foreign owner instance");
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
        if (isClosing()) {
            fail("receiver registration after the process closing boundary");
            throw new SecurityException(
                "guarded capture refuses a registration after closing");
        }
        String rejection = rejectionOf(receiver, filter, flags, overload);
        if (rejection != null) {
            fail(rejection);
            throw new SecurityException("guarded capture refused: " + rejection);
        }
        BroadcastReceiver wrapper = new GuardedReceiver(receiver);
        synchronized (lock) {
            // The closing decision is rechecked atomically with the reservation,
            // immediately before the owned handle is inserted.
            if (closing) {
                fail("receiver registration after the process closing boundary");
                throw new SecurityException(
                    "guarded capture refuses a registration after closing");
            }
            if (wrappers.containsKey(receiver)) {
                fail("duplicate registration of the same receiver");
                throw new SecurityException("guarded capture refused a duplicate registration");
            }
            // Reserve the exact native mapping and owned wrapper BEFORE the
            // effect, so a throwing platform call cannot lose the handle.
            wrappers.put(receiver, wrapper);
            ownedReceivers.add(wrapper);
        }
        Intent sticky;
        try {
            sticky = super.registerReceiver(wrapper, filter, flags);
        } catch (Throwable error) {
            // The handle stays owned: the platform may have registered it.
            fail("registration failed: " + stackTraceOf(error));
            throw error instanceof SecurityException ? (SecurityException) error
                : new SecurityException("guarded registration failed: " + error, error);
        }
        successfulRegistrations.incrementAndGet();
        synchronized (lock) {
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
    /**
     * Whether this object is the approved class as resolved through the stored
     * verified target loader. A same-named class from another loader is a
     * different class and is refused.
     */
    private static boolean isApproved(Class<?> candidate, String name) {
        if (candidate == null) return false;
        ClassLoader loader;
        synchronized (lock) {
            loader = targetLoader;
        }
        if (loader == null) return false;
        try {
            return Class.forName(name, false, loader) == candidate;
        } catch (Throwable error) {
            return false;
        }
    }

    private static String rejectionOf(BroadcastReceiver receiver, IntentFilter filter,
            int flags, String overload) {
        if (receiver == null || filter == null) return "registration without a receiver or filter";
        if (!isApproved(receiver.getClass(), LEB_RECEIVER)) {
            return "unexpected receiver class " + receiver.getClass().getName();
        }
        // The plain filter class is checked BEFORE any getter runs, so an
        // unapproved subclass can never execute its own method bodies.
        if (filter.getClass() != IntentFilter.class) {
            return "unexpected filter class " + filter.getClass().getName();
        }
        JSONArray actions = actionsOf(filter);
        if (actions.length() != 1 || !LEB_IPC_ACTION.equals(actions.optString(0))) {
            return "unexpected filter actions " + actions;
        }
        if (filter.countDataTypes() != 0 || filter.countDataSchemes() != 0
                || filter.countCategories() != 0 || filter.countDataAuthorities() != 0
                || filter.countDataPaths() != 0
                || filter.countDataSchemeSpecificParts() != 0) {
            return "unexpected filter data or categories";
        }
        if (!"3-arg".equals(overload) || flags != 2) {
            return "unexpected registration overload or flags " + overload + "/" + flags;
        }
        return null;
    }

    private Intent refuseOverload(String overload, BroadcastReceiver receiver, IntentFilter filter) {
        // The diagnostic must never invoke an unapproved filter's own methods.
        fail("unexpected registration overload " + overload + " for "
            + (receiver == null ? "null" : receiver.getClass().getName())
            + " filterClass=" + (filter == null ? "null" : filter.getClass().getName()));
        throw new SecurityException("guarded capture refuses the " + overload
            + " registerReceiver overload");
    }

    @Override
    public void unregisterReceiver(BroadcastReceiver receiver) {
        if (!isArmed()) {
            super.unregisterReceiver(receiver);
            return;
        }
        // A foreign instance must be refused before any delegate effect, even
        // when the handle is really owned by the armed owner.
        if (!isOwner()) {
            foreignUnregistrations.incrementAndGet();
            fail("unregister of a receiver by a foreign owner instance");
            throw new SecurityException("guarded capture refuses a foreign unregistration");
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
        try {
            super.unregisterReceiver(wrapper);
        } catch (Throwable error) {
            // The handle stays owned: without an acknowledgement the removal is
            // uncertain, and the complete cause is retained.
            fail("receiver removal failed: " + stackTraceOf(error));
            throw error instanceof SecurityException ? (SecurityException) error
                : new SecurityException("guarded receiver removal failed: " + error, error);
        }
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
            fail("lifecycle registration by a foreign owner instance");
            throw new SecurityException("this instance is not the armed capture owner");
        }
        attemptedRegistrations.incrementAndGet();
        if (isClosing()) {
            fail("lifecycle registration after the process closing boundary");
            throw new SecurityException(
                "guarded capture refuses a lifecycle registration after closing");
        }
        if (callback == null || !isApproved(callback.getClass(), LEB_LIFECYCLE)) {
            fail("unexpected lifecycle callback "
                + (callback == null ? "null" : callback.getClass().getName()));
            throw new SecurityException("guarded capture refused an unexpected lifecycle callback");
        }
        // Reserve the exact callback BEFORE the effect, so a throwing platform
        // call cannot lose the handle.
        synchronized (lock) {
            // The closing decision is rechecked atomically with the reservation.
            if (closing) {
                fail("lifecycle registration after the process closing boundary");
                throw new SecurityException(
                    "guarded capture refuses a lifecycle registration after closing");
            }
            if (ownedCallbacks.contains(callback)) {
                fail("duplicate registration of the same lifecycle callback");
                throw new SecurityException("guarded capture refused a duplicate lifecycle");
            }
            ownedCallbacks.add(callback);
        }
        try {
            super.registerActivityLifecycleCallbacks(callback);
        } catch (Throwable error) {
            fail("lifecycle registration failed: " + stackTraceOf(error));
            throw error instanceof SecurityException ? (SecurityException) error
                : new SecurityException("guarded lifecycle registration failed: " + error, error);
        }
        successfulRegistrations.incrementAndGet();
        synchronized (lock) {
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
        // A foreign instance must be refused before any native attempt, even when
        // the callback is really owned: its own super would normally no-op and
        // then wrongly clear the true owner's handle.
        if (!isOwner()) {
            foreignUnregistrations.incrementAndGet();
            fail("unregister of a lifecycle callback by a foreign owner instance");
            throw new SecurityException(
                "guarded capture refuses a foreign lifecycle unregistration");
        }
        synchronized (lock) {
            if (!ownedCallbacks.contains(callback)) {
                foreignUnregistrations.incrementAndGet();
                fail("unregister of a lifecycle callback the guard does not own");
                throw new SecurityException(
                    "guarded capture refuses a foreign lifecycle unregistration");
            }
        }
        try {
            super.unregisterActivityLifecycleCallbacks(callback);
        } catch (Throwable error) {
            // The handle stays owned: without an acknowledgement the removal is
            // uncertain, and the complete cause is retained.
            fail("lifecycle removal failed: " + stackTraceOf(error));
            throw error instanceof SecurityException ? (SecurityException) error
                : new SecurityException("guarded lifecycle removal failed: " + error, error);
        }
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
