package io.liber.oracle.nested;

/** Blocks shortcut-service access; only the known startup publication may be handled. */
final class ShortcutStartupGuard {
    static final String SERVICE = "shortcut";
    static final String PROVIDER = "io.legado.app.api.ReaderProvider";
    private Marker issued;
    private int intercepted;
    private int handled;
    private boolean beforeBinding;

    static final class Marker extends RuntimeException {
        private Marker() { super("selected scratch refused shortcut-service access"); }
    }

    synchronized void intercept(String name, boolean bound) {
        if (!SERVICE.equals(name)) return;
        Marker marker = new Marker();
        intercepted++;
        if (issued == null && intercepted == 1 && !bound) {
            issued = marker;
            beforeBinding = true;
        }
        throw marker;
    }

    synchronized boolean handle(Object object, Throwable error) {
        if (object != null || error != issued || issued == null || handled != 0
                || intercepted != 1 || !beforeBinding || !knownProviderStack(error)) return false;
        handled++;
        return true;
    }

    private static boolean knownProviderStack(Throwable error) {
        String[] classes = {"androidx.core.content.pm.ShortcutManagerCompat",
            "io.legado.app.api.ShortCuts", PROVIDER};
        String[] methods = {"setDynamicShortcuts", "buildShortCuts", "onCreate"};
        int index = 0;
        for (StackTraceElement frame : error.getStackTrace()) {
            if (index < classes.length && classes[index].equals(frame.getClassName())
                    && methods[index].equals(frame.getMethodName())) index++;
        }
        return index == classes.length;
    }

    synchronized boolean verified() {
        return issued != null && intercepted == 1 && handled == 1 && beforeBinding;
    }

    synchronized int intercepted() { return intercepted; }
    synchronized int handled() { return handled; }
    synchronized boolean beforeBinding() { return beforeBinding; }
}
