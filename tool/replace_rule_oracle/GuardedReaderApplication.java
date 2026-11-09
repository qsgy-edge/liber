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
 * <p>While armed, the guard is the single owner of the resources the selected
 * saved-content route creates: the exported {@code ACTION_LEB_IPC} receiver the
 * LiveEventBus singleton registers, the application lifecycle callback
 * {@code AppUtils} registers, and the per-case save-event observer. It accepts
 * only the exact registrations the inspected target actually performs, refuses
 * everything else before any platform effect, and records attempted versus
 * successful work so a failed or uncertain handle stays visible.
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
    private static final AtomicInteger saveEvents = new AtomicInteger();
    private static final AtomicInteger foreignEvents = new AtomicInteger();
    private static final AtomicInteger callbackErrors = new AtomicInteger();
    private static volatile JSONObject lastEvent = new JSONObject();

    public GuardedReaderApplication() {
        owner = this;
    }

    static int launchAttempts() { return attempts.get(); }

    /**
     * Arms the guard for this process lifetime with the exact owner and target
     * classloader the capture already proved. Called once, before any reference
     * class can reach the saved-content route.
     */
    public static void arm(Application application, ClassLoader loader) {
        synchronized (lock) {
            owner = application instanceof GuardedReaderApplication
                ? (GuardedReaderApplication) application : null;
            targetLoader = loader;
            armed = true;
        }
    }

    static boolean isArmed() {
        synchronized (lock) {
            return armed;
        }
    }

    /**
     * Removes every process-owned registration once, at the end of the whole
     * lifetime. Answers whether every owned resource is gone.
     */
    public static JSONObject releaseProcessResources() {
        List<BroadcastReceiver> receivers;
        List<ActivityLifecycleCallbacks> callbacks;
        GuardedReaderApplication exactOwner;
        synchronized (lock) {
            receivers = new ArrayList<>(ownedReceivers);
            callbacks = new ArrayList<>(ownedCallbacks);
            ownedReceivers.clear();
            ownedCallbacks.clear();
            exactOwner = owner;
        }
        int removedReceivers = 0;
        int removedCallbacks = 0;
        JSONArray removalFailures = new JSONArray();
        for (BroadcastReceiver wrapper : receivers) {
            try {
                if (exactOwner == null) {
                    throw new IllegalStateException("no exact owner to remove a receiver through");
                }
                exactOwner.superUnregisterReceiver(wrapper);
                removedReceivers++;
                receiverUnregistrations.put(wrapper.getClass().getName());
            } catch (Throwable error) {
                removalFailures.put("receiver: " + error);
                guardFailures.put("receiver removal failed: " + error);
            }
        }
        for (ActivityLifecycleCallbacks callback : callbacks) {
            try {
                if (exactOwner == null) {
                    throw new IllegalStateException("no exact owner to remove a callback through");
                }
                exactOwner.superUnregisterCallbacks(callback);
                removedCallbacks++;
                lifecycleUnregistrations.put(callback.getClass().getName());
            } catch (Throwable error) {
                removalFailures.put("lifecycle: " + error);
                guardFailures.put("lifecycle removal failed: " + error);
            }
        }
        synchronized (lock) {
            wrappers.clear();
        }
        JSONObject receipt = new JSONObject();
        try {
            receipt.put("ownedReceivers", receivers.size())
                .put("removedReceivers", removedReceivers)
                .put("ownedLifecycleCallbacks", callbacks.size())
                .put("removedLifecycleCallbacks", removedCallbacks)
                .put("removalFailures", removalFailures)
                .put("closed", removalFailures.length() == 0
                    && removedReceivers == receivers.size()
                    && removedCallbacks == callbacks.size());
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
                .put("saveEvents", saveEvents.get())
                .put("foreignEvents", foreignEvents.get())
                .put("callbackErrors", callbackErrors.get())
                .put("observing", observing)
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
        if (!isArmed()) throw new IllegalStateException("the capture guard is not armed");
        final ClassLoader loader = targetLoader;
        if (loader == null) throw new IllegalStateException("no target classloader");
        expectBookUrl = bookUrl;
        expectChapterUrl = chapterUrl;
        saveEvents.set(0);
        foreignEvents.set(0);
        callbackErrors.set(0);
        lastEvent = new JSONObject();
        return onMain(() -> {
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
     * the main thread and acknowledges that executed call.
     */
    public static JSONObject endSaveObservation(long timeoutMillis) throws Exception {
        JSONObject result = new JSONObject();
        long deadline = System.currentTimeMillis() + timeoutMillis;
        while (saveEvents.get() == 0 && System.currentTimeMillis() < deadline) {
            Thread.sleep(5);
        }
        result.put("events", saveEvents.get())
            .put("foreignEvents", foreignEvents.get())
            .put("callbackErrors", callbackErrors.get())
            .put("lastEvent", new JSONObject(lastEvent.toString()));
        JSONObject removal = onMain(() -> {
            Object observable = saveObservable;
            Object observer = saveObserver;
            Method remove = removeMethod;
            if (observable == null || observer == null || remove == null) {
                throw new IllegalStateException("no observer to remove");
            }
            remove.invoke(observable, observer);
            observing = false;
            saveObservable = null;
            saveObserver = null;
            return new JSONObject()
                .put("interface", OBSERVABLE_INTERFACE)
                .put("declaringClass", remove.getDeclaringClass().getName())
                .put("onMain", Looper.myLooper() == Looper.getMainLooper())
                .put("removed", true);
        });
        result.put("removal", removal);
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
                        lastEvent = new JSONObject()
                            .put("bookUrl", bookUrl == null ? JSONObject.NULL : bookUrl)
                            .put("chapterUrl", chapterUrl == null ? JSONObject.NULL : chapterUrl)
                            .put("correlates", correlates);
                    } catch (Throwable error) {
                        callbackErrors.incrementAndGet();
                        try {
                            guardFailures.put("save callback failed: " + error);
                        } catch (Throwable ignored) {
                            // The counter already records it.
                        }
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

    /** Runs one callable on the main thread and returns its actual result. */
    static JSONObject onMain(Callable<JSONObject> work) throws Exception {
        if (Looper.myLooper() == Looper.getMainLooper()) return work.call();
        final Object[] value = new Object[1];
        final Throwable[] failure = new Throwable[1];
        final CountDownLatch latch = new CountDownLatch(1);
        boolean posted = new Handler(Looper.getMainLooper()).post(() -> {
            try {
                value[0] = work.call();
            } catch (Throwable error) {
                failure[0] = error;
            } finally {
                latch.countDown();
            }
        });
        if (!posted) throw new IllegalStateException("the main looper refused the work");
        if (!latch.await(30000, TimeUnit.MILLISECONDS)) {
            throw new IllegalStateException("main-thread work did not complete");
        }
        if (failure[0] != null) {
            throw failure[0] instanceof Exception
                ? (Exception) failure[0] : new IllegalStateException(failure[0]);
        }
        return value[0] instanceof JSONObject ? (JSONObject) value[0] : new JSONObject();
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
        return guardRegister(receiver, filter, 0, "2-arg");
    }

    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter, int flags) {
        if (!isArmed()) return super.registerReceiver(receiver, filter, flags);
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
            try {
                guardFailures.put(rejection);
            } catch (Throwable ignored) {
                // The refusal below is the visible outcome.
            }
            throw new SecurityException("guarded capture refused: " + rejection);
        }
        BroadcastReceiver wrapper = new GuardedReceiver(receiver);
        synchronized (lock) {
            if (wrappers.containsKey(receiver)) {
                try {
                    guardFailures.put("duplicate registration of the same receiver");
                } catch (Throwable ignored) {
                    // The refusal below is the visible outcome.
                }
                throw new SecurityException("guarded capture refused a duplicate registration");
            }
            wrappers.put(receiver, wrapper);
        }
        Intent sticky;
        try {
            sticky = super.registerReceiver(wrapper, filter, flags);
        } catch (Throwable error) {
            synchronized (lock) {
                wrappers.remove(receiver);
            }
            try {
                guardFailures.put("registration failed: " + error);
            } catch (Throwable ignored) {
                // The rethrown failure is the visible outcome.
            }
            throw error instanceof SecurityException ? (SecurityException) error
                : new SecurityException("guarded registration failed: " + error, error);
        }
        successfulRegistrations.incrementAndGet();
        synchronized (lock) {
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
        if ("3-arg".equals(overload) && flags != 2) return "unexpected registration flags " + flags;
        if ("2-arg".equals(overload) && flags != 0) return "unexpected registration flags " + flags;
        return null;
    }

    private Intent refuseOverload(String overload, BroadcastReceiver receiver, IntentFilter filter) {
        try {
            guardFailures.put("unexpected registration overload " + overload
                + " for " + (receiver == null ? "null" : receiver.getClass().getName())
                + " actions=" + actionsOf(filter));
        } catch (Throwable ignored) {
            // The refusal below is the visible outcome.
        }
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
            wrapper = wrappers.remove(receiver);
        }
        if (wrapper == null) {
            foreignUnregistrations.incrementAndGet();
            try {
                guardFailures.put("unregister of a receiver the guard does not own: "
                    + (receiver == null ? "null" : receiver.getClass().getName()));
            } catch (Throwable ignored) {
                // The platform answer below is the visible outcome.
            }
            super.unregisterReceiver(receiver);
            return;
        }
        super.unregisterReceiver(wrapper);
        synchronized (lock) {
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
        attemptedRegistrations.incrementAndGet();
        if (callback == null || !LEB_LIFECYCLE.equals(callback.getClass().getName())) {
            try {
                guardFailures.put("unexpected lifecycle callback "
                    + (callback == null ? "null" : callback.getClass().getName()));
            } catch (Throwable ignored) {
                // The refusal below is the visible outcome.
            }
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
            if (!ownedCallbacks.remove(callback)) {
                foreignUnregistrations.incrementAndGet();
                try {
                    guardFailures.put("unregister of a lifecycle callback the guard does not own");
                } catch (Throwable ignored) {
                    // The platform answer below is the visible outcome.
                }
            }
        }
        super.unregisterActivityLifecycleCallbacks(callback);
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
