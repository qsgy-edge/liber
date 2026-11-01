package io.liber.oracle.nested;

/** Host-side discrimination controls; not evidence of Android provider startup. */
public final class ShortcutStartupGuardTest {
    private static void require(boolean value) {
        if (!value) throw new AssertionError();
    }

    private static Throwable intercept(ShortcutStartupGuard guard, boolean bound) {
        try {
            guard.intercept("shortcut", bound);
            throw new AssertionError("shortcut was not refused");
        } catch (ShortcutStartupGuard.Marker marker) {
            return marker;
        }
    }

    private static void providerStack(Throwable error) {
        error.setStackTrace(new StackTraceElement[]{
            new StackTraceElement("androidx.core.content.pm.ShortcutManagerCompat", "setDynamicShortcuts", "x", 1),
            new StackTraceElement("io.legado.app.api.ShortCuts", "buildShortCuts", "x", 1),
            new StackTraceElement("io.legado.app.api.ReaderProvider", "onCreate", "x", 1)});
    }

    public static void main(String[] args) {
        ShortcutStartupGuard guard = new ShortcutStartupGuard();
        guard.intercept("other", false);
        require(!guard.verified());
        Throwable marker = intercept(guard, false);
        providerStack(marker);
        require(!guard.handle(new Object(), marker));
        require(!guard.handle(null, new RuntimeException(marker)));
        require(!new ShortcutStartupGuard().handle(null, marker));
        require(guard.handle(null, marker));
        require(guard.verified());
        require(!guard.handle(null, marker));
        intercept(guard, false);
        require(!guard.verified());

        ShortcutStartupGuard wrong = new ShortcutStartupGuard();
        Throwable wrongMarker = intercept(wrong, false);
        require(!wrong.handle(null, wrongMarker));
        require(!wrong.verified());
        ShortcutStartupGuard late = new ShortcutStartupGuard();
        Throwable lateMarker = intercept(late, true);
        providerStack(lateMarker);
        require(!late.handle(null, lateMarker));
        require(!late.verified());
        System.out.println("ShortcutStartupGuard discrimination controls passed; Android startup not run");
    }
}
