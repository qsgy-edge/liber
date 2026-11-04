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
}
