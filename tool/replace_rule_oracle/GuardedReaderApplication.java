package io.liber.oracle.nested;

import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Refuses the selected reader's restart before it can launch the real app.
 *
 * <p>It also carries one bounded, opt-in capture guard for the approved
 * saved-content observation. The guard is inert unless {@link #beginCapture()}
 * was called for this process lifetime, so every other consumer of this class
 * keeps exactly the previous behaviour: two activity-launch refusals and
 * nothing else.
 *
 * <p>The guard exists because the selected {@code BookHelp.saveContent} posts
 * its save event through LiveEventBus, whose first use constructs a core that
 * registers an exported {@code ACTION_LEB_IPC} receiver and an application
 * lifecycle callback. Both are real Android registrations outside the scratch
 * filesystem and outside the collector's Coroutine-only terminal proof. While
 * the guard is enabled it:
 *
 * <ul>
 *   <li>registers its own wrapper in place of the native receiver and never
 *       delivers an inbound IPC intent to the native receiver, so an external
 *       attempt is recorded as a capture failure instead of being decoded;</li>
 *   <li>tracks the exact wrapper/lifecycle registrations it owns so they can be
 *       removed again;</li>
 *   <li>offers a main-looper fence so a posted save event's handler work is
 *       proven to have run before terminal success is claimed.</li>
 * </ul>
 */
public final class GuardedReaderApplication extends Application {
    private static final AtomicInteger attempts = new AtomicInteger();

    private static final Object captureLock = new Object();
    private static boolean captureEnabled;
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

    public GuardedReaderApplication() {
        GuardedReaderApplicationHolder.instance = this;
    }

    static int launchAttempts() { return attempts.get(); }

    /** Enables the capture guard for this process lifetime. */
    public static void beginCapture() {
        synchronized (captureLock) {
            captureEnabled = true;
        }
    }

    /** Disables the guard; owned registrations must already be removed. */
    public static void endCapture() {
        synchronized (captureLock) {
            captureEnabled = false;
        }
    }

    private static boolean captureActive() {
        synchronized (captureLock) {
            return captureEnabled;
        }
    }

    /**
     * Removes every registration this guard owns and answers whether all of
     * them are gone. Called once, from the collector's cleanup path.
     */
    public static JSONObject releaseOwnedRegistrations() {
        JSONObject receipt = new JSONObject();
        List<BroadcastReceiver> receivers;
        List<ActivityLifecycleCallbacks> callbacks;
        synchronized (captureLock) {
            receivers = new ArrayList<>(ownedReceivers);
            callbacks = new ArrayList<>(ownedCallbacks);
            ownedReceivers.clear();
            ownedCallbacks.clear();
        }
        int removedReceivers = 0;
        int removedCallbacks = 0;
        try {
            Application application = currentApplication();
            GuardedReaderApplication guard = application instanceof GuardedReaderApplication
                ? (GuardedReaderApplication) application : null;
            for (BroadcastReceiver wrapper : receivers) {
                try {
                    if (guard != null) guard.superUnregisterReceiver(wrapper);
                    else application.unregisterReceiver(wrapper);
                    removedReceivers++;
                    receiverUnregistrations.put(wrapper.getClass().getName());
                } catch (Throwable error) {
                    guardFailures.put("receiver removal failed: " + error);
                }
            }
            for (ActivityLifecycleCallbacks callback : callbacks) {
                try {
                    if (guard != null) guard.superUnregisterCallbacks(callback);
                    else application.unregisterActivityLifecycleCallbacks(callback);
                    removedCallbacks++;
                    lifecycleUnregistrations.put(callback.getClass().getName());
                } catch (Throwable error) {
                    guardFailures.put("lifecycle removal failed: " + error);
                }
            }
            synchronized (captureLock) {
                wrappers.clear();
            }
            receipt.put("ownedReceivers", receivers.size())
                .put("removedReceivers", removedReceivers)
                .put("ownedLifecycleCallbacks", callbacks.size())
                .put("removedLifecycleCallbacks", removedCallbacks);
        } catch (Throwable error) {
            try {
                guardFailures.put("registration release failed: " + error);
            } catch (Throwable ignored) {
                // The failure is still visible through the thrown state below.
            }
            try {
                receipt.put("ownedReceivers", receivers.size())
                    .put("removedReceivers", removedReceivers)
                    .put("ownedLifecycleCallbacks", callbacks.size())
                    .put("removedLifecycleCallbacks", removedCallbacks)
                    .put("error", String.valueOf(error));
            } catch (Throwable ignored) {
                // Receipt assembly cannot itself hide the failure.
            }
        }
        return receipt;
    }

    /** The guard's own receipts; read once at cleanup. */
    public static JSONObject captureReceipt() throws Exception {
        JSONObject receipt = new JSONObject();
        synchronized (captureLock) {
            receipt.put("enabled", captureEnabled)
                .put("receiverRegistrations", new JSONArray(receiverRegistrations.toString()))
                .put("receiverUnregistrations", new JSONArray(receiverUnregistrations.toString()))
                .put("lifecycleRegistrations", new JSONArray(lifecycleRegistrations.toString()))
                .put("lifecycleUnregistrations", new JSONArray(lifecycleUnregistrations.toString()))
                .put("inboundAttempts", new JSONArray(inboundAttempts.toString()))
                .put("failures", new JSONArray(guardFailures.toString()))
                .put("blockedDeliveries", blockedDeliveries.get())
                .put("foreignUnregistrations", foreignUnregistrations.get())
                .put("pendingWrappers", wrappers.size());
        }
        return receipt;
    }

    /**
     * Posts a marker to the main looper and waits for it. Everything the save
     * path posted before this call has run when it returns, so a save event's
     * handler work is a measured prerequisite rather than a copied boolean.
     */
    public static JSONObject fenceMainLooper(long timeoutMillis) throws Exception {
        final CountDownLatch latch = new CountDownLatch(1);
        boolean posted = new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override public void run() { latch.countDown(); }
        });
        boolean completed = posted && latch.await(timeoutMillis, TimeUnit.MILLISECONDS);
        return new JSONObject()
            .put("posted", posted)
            .put("completed", completed)
            .put("timeoutMillis", timeoutMillis)
            .put("mainThread", Looper.myLooper() == Looper.getMainLooper());
    }

    private static Application currentApplication() {
        Application application = null;
        try {
            Object thread = Class.forName("android.app.ActivityThread")
                .getMethod("currentActivityThread").invoke(null);
            application = (Application) thread.getClass()
                .getMethod("getApplication").invoke(thread);
        } catch (Throwable ignored) {
            // Falls back to the guard's own instance below.
        }
        return application != null ? application : GuardedReaderApplicationHolder.instance();
    }

    /** Holds the instance this class was constructed as, for the fallback path. */
    private static final class GuardedReaderApplicationHolder {
        private static volatile Application instance;

        static Application instance() { return instance; }
    }

    @Override public void startActivity(Intent intent) {
        attempts.incrementAndGet();
        throw new SecurityException("selected reader refused activity launch");
    }

    @Override public void startActivity(Intent intent, Bundle options) {
        attempts.incrementAndGet();
        throw new SecurityException("selected reader refused activity launch");
    }

    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter) {
        if (!captureActive()) return super.registerReceiver(receiver, filter);
        return guardRegister(receiver, filter, 0, "2-arg");
    }

    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter, int flags) {
        if (!captureActive()) return super.registerReceiver(receiver, filter, flags);
        return guardRegister(receiver, filter, flags, "3-arg");
    }

    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter,
            String broadcastPermission, Handler scheduler) {
        if (!captureActive()) {
            return super.registerReceiver(receiver, filter, broadcastPermission, scheduler);
        }
        return refuseOverload("4-arg", receiver, filter);
    }

    @Override
    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter,
            String broadcastPermission, Handler scheduler, int flags) {
        if (!captureActive()) {
            return super.registerReceiver(receiver, filter, broadcastPermission, scheduler, flags);
        }
        return refuseOverload("5-arg", receiver, filter);
    }

    private Intent guardRegister(BroadcastReceiver receiver, IntentFilter filter, int flags,
            String overload) {
        try {
            if (receiver == null || filter == null) {
                guardFailures.put("registration without a receiver or filter (" + overload + ")");
                throw new SecurityException("guarded registration needs a receiver and a filter");
            }
            BroadcastReceiver wrapper = new GuardedReceiver(receiver);
            synchronized (captureLock) {
                wrappers.put(receiver, wrapper);
                ownedReceivers.add(wrapper);
                receiverRegistrations.put(new JSONObject()
                    .put("overload", overload)
                    .put("nativeClass", receiver.getClass().getName())
                    .put("wrapperClass", wrapper.getClass().getName())
                    .put("flags", flags)
                    .put("actions", actionsOf(filter)));
            }
            return super.registerReceiver(wrapper, filter, flags);
        } catch (SecurityException refused) {
            throw refused;
        } catch (Throwable error) {
            throw new SecurityException("guarded registration failed: " + error, error);
        }
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
        if (!captureActive()) {
            super.unregisterReceiver(receiver);
            return;
        }
        BroadcastReceiver wrapper;
        synchronized (captureLock) {
            wrapper = wrappers.remove(receiver);
        }
        if (wrapper == null) {
            foreignUnregistrations.incrementAndGet();
            try {
                guardFailures.put("unregister of a receiver the guard does not own: "
                    + (receiver == null ? "null" : receiver.getClass().getName()));
            } catch (Throwable ignored) {
                // The super call below reports the platform's own answer.
            }
            super.unregisterReceiver(receiver);
            return;
        }
        try {
            receiverUnregistrations.put(wrapper.getClass().getName());
        } catch (Throwable ignored) {
            // The removal itself is what matters.
        }
        super.unregisterReceiver(wrapper);
    }

    @Override
    public void registerActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
        if (!captureActive()) {
            super.registerActivityLifecycleCallbacks(callback);
            return;
        }
        if (callback == null) {
            try {
                guardFailures.put("lifecycle registration without a callback");
            } catch (Throwable ignored) {
                // The platform refusal below is the visible outcome.
            }
            throw new SecurityException("guarded lifecycle registration needs a callback");
        }
        synchronized (captureLock) {
            ownedCallbacks.add(callback);
            try {
                lifecycleRegistrations.put(callback.getClass().getName());
            } catch (Throwable ignored) {
                // The registration itself is what matters.
            }
        }
        super.registerActivityLifecycleCallbacks(callback);
    }

    @Override
    public void unregisterActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
        if (!captureActive()) {
            super.unregisterActivityLifecycleCallbacks(callback);
            return;
        }
        synchronized (captureLock) {
            ownedCallbacks.remove(callback);
            try {
                lifecycleUnregistrations.put(
                    callback == null ? "null" : callback.getClass().getName());
            } catch (Throwable ignored) {
                // The removal itself is what matters.
            }
        }
        super.unregisterActivityLifecycleCallbacks(callback);
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
     * delivers to the native receiver and never inspects the intent's extras:
     * an inbound IPC attempt is a capture failure, not a silently contained
     * success.
     */
    private static final class GuardedReceiver extends BroadcastReceiver {
        private final BroadcastReceiver delegate;

        GuardedReceiver(BroadcastReceiver delegate) { this.delegate = delegate; }

        @Override public void onReceive(Context context, Intent intent) {
            blockedDeliveries.incrementAndGet();
            synchronized (captureLock) {
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
