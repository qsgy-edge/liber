package io.liber.oracle.nested;

import android.app.Application;
import android.content.Context;
import org.json.JSONObject;

/** Package-local access to the existing selected-reference host safeguards. */
public final class SelectedFieldHostBridge {
    private SelectedFieldHostBridge() {}

    public static StateSessionOracle.ScratchContext guardedScratch(
            Context context, String rootName, String preferencePrefix) {
        return new StateSessionOracle.ScratchContext(context, rootName, preferencePrefix, true);
    }

    public static boolean handleShortcutException(StateSessionOracle.ScratchContext scratch,
            Object object, Throwable error) {
        return scratch.handleShortcutException(object, error);
    }

    public static JSONObject shortcutReceipt(StateSessionOracle.ScratchContext scratch)
            throws Exception {
        return scratch.shortcutReceipt();
    }

    public static JSONObject initialize(ClassLoader loader, JSONObject declaration)
            throws Exception {
        return HostRuntimeInit.initialize(loader, declaration);
    }

    public static int launchAttempts() {
        return GuardedReaderApplication.launchAttempts();
    }

    /** Arms the one process-lifetime capture guard with its exact owner. */
    public static void arm(Application application, ClassLoader loader) {
        GuardedReaderApplication.arm(application, loader);
    }

    /** Whether the guard recorded a capture failure that must fail the run. */
    public static boolean captureFailed() {
        return GuardedReaderApplication.captureFailed();
    }

    /** Whether the capture guard is armed for this lifetime. */
    public static boolean armed() {
        return GuardedReaderApplication.isArmed();
    }

    /** Registers this case's save-event observer on the main thread. */
    public static JSONObject beginSaveObservation(String bookUrl, String chapterUrl)
            throws Exception {
        return GuardedReaderApplication.beginSaveObservation(bookUrl, chapterUrl);
    }

    /** Waits for the correlated event, then removes the observer on the main thread. */
    public static JSONObject endSaveObservation(long timeoutMillis) throws Exception {
        return GuardedReaderApplication.endSaveObservation(timeoutMillis);
    }

    /** Removes every process-owned registration once, at the end of the lifetime. */
    public static JSONObject releaseProcessResources() {
        return GuardedReaderApplication.releaseProcessResources();
    }

    /** The guard's own registration/observer/failure receipts. */
    public static JSONObject captureReceipt() throws Exception {
        return GuardedReaderApplication.captureReceipt();
    }

    /** Posts a marker to the main looper and waits for it. */
    public static JSONObject fenceMainLooper(long timeoutMillis) throws Exception {
        return GuardedReaderApplication.fenceMainLooper(timeoutMillis);
    }
}
