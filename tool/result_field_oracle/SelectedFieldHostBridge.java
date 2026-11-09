package io.liber.oracle.nested;

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

    /** Enables the bounded saved-content capture guard for this lifetime. */
    public static void beginCapture() {
        GuardedReaderApplication.beginCapture();
    }

    /** Disables the guard after its owned registrations were released. */
    public static void endCapture() {
        GuardedReaderApplication.endCapture();
    }

    /** Removes every registration the guard owns and reports the outcome. */
    public static JSONObject releaseOwnedRegistrations() {
        return GuardedReaderApplication.releaseOwnedRegistrations();
    }

    /** The guard's own registration/inbound/failure receipts. */
    public static JSONObject captureReceipt() throws Exception {
        return GuardedReaderApplication.captureReceipt();
    }

    /** Posts a marker to the main looper and waits for it. */
    public static JSONObject fenceMainLooper(long timeoutMillis) throws Exception {
        return GuardedReaderApplication.fenceMainLooper(timeoutMillis);
    }
}
