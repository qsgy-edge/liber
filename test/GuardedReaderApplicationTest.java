package io.liber.oracle.nested;

import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import org.json.JSONObject;

/**
 * Actual behavioural controls for the capture guard.
 *
 * <p>This runs the real {@link GuardedReaderApplication} against bounded OS and
 * dependency boundary fakes on a plain JVM. Each control runs in its own JVM so
 * the guard's process-lifetime state starts clean; the two-saved-case control
 * deliberately exercises both cases in one lifetime.
 *
 * <p>Usage: {@code java io.liber.oracle.nested.GuardedReaderApplicationTest
 * <control>} prints one JSON result and exits 0 on success. It is host evidence
 * for the guard's ownership, refusal, observer and closure behaviour, not
 * Android execution evidence.
 */
public final class GuardedReaderApplicationTest {
    /** A stand-in for the reference Book payload the save event carries. */
    public static final class FakeBook {
        private final String bookUrl;
        public FakeBook(String bookUrl) { this.bookUrl = bookUrl; }
        public String getBookUrl() { return bookUrl; }
    }

    /** A stand-in for the reference BookChapter payload. */
    public static final class FakeChapter {
        private final String url;
        public FakeChapter(String url) { this.url = url; }
        public String getUrl() { return url; }
    }

    /** A receiver the guard must refuse. */
    public static final class ForeignReceiver extends BroadcastReceiver {
        @Override public void onReceive(Context context, Intent intent) {}
    }

    /** A lifecycle callback the guard must refuse. */
    public static final class ForeignLifecycle
            implements Application.ActivityLifecycleCallbacks {
        @Override public void onActivityCreated(Object activity, android.os.Bundle state) {}
    }

    static final String ACTION = GuardedReaderApplication.LEB_IPC_ACTION;

    public static void main(String[] args) throws Exception {
        String control = args.length == 0 ? "all" : args[0];
        JSONObject result = new JSONObject().put("control", control);
        switch (control) {
            case "inactive-unchanged": inactiveUnchanged(result); break;
            case "exact-registration": exactRegistration(result); break;
            case "two-arg-refused": twoArgRefused(result); break;
            case "wrong-registrations": wrongRegistrations(result); break;
            case "ipc-not-delivered": ipcNotDelivered(result); break;
            case "registration-failure": registrationFailure(result); break;
            case "foreign-unregister-refused": foreignUnregisterRefused(result); break;
            case "failed-release-retains": failedReleaseRetains(result); break;
            case "double-end-idempotent": doubleEndIdempotent(result); break;
            case "release-closes-observer": releaseClosesObserver(result); break;
            case "owner-not-overwritten": ownerNotOverwritten(result); break;
            case "arm-rejects": armRejects(result); break;
            case "foreign-event-fails": foreignEventFails(result); break;
            case "abandoned-registration": abandonedRegistration(result); break;
            case "two-saved-cases": twoSavedCases(result); break;
            default: throw new IllegalArgumentException("unknown control " + control);
        }
        result.put("ok", true);
        System.out.println(result.toString());
    }

    // --- controls ---------------------------------------------------------

    private static void inactiveUnchanged(JSONObject result) throws Exception {
        GuardedReaderApplication app = new GuardedReaderApplication();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION));
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        result.put("nativeRegisterCalls", app.registered.size())
            .put("wrapped", app.lastReceiver != receiver)
            .put("armed", GuardedReaderApplication.isArmed());
        boolean first = false;
        boolean second = false;
        try { app.startActivity(new Intent("x")); } catch (SecurityException expected) { first = true; }
        try { app.startActivity(new Intent("x"), new android.os.Bundle()); }
        catch (SecurityException expected) { second = true; }
        result.put("bothLaunchRefusals", first && second);
        require(app.registered.size() == 2, "inactive overloads must forward unchanged");
        require(app.lastReceiver == receiver,
            "an inactive registration must not be wrapped");
    }

    private static void exactRegistration(JSONObject result) throws Exception {
        GuardedReaderApplication app = arm();
        app.registerReceiver(newReceiver(), new IntentFilter(ACTION), 2);
        result.put("nativeRegisterCalls", app.registered.size())
            .put("successful", GuardedReaderApplication.captureReceipt()
                .optInt("successfulRegistrations"));
        require(app.registered.size() == 1, "the exact registration must reach the platform");
        require(GuardedReaderApplication.captureReceipt().optInt("successfulRegistrations") == 1,
            "a successful registration must be counted after the platform return");
        require(!GuardedReaderApplication.captureFailed(), "the exact registration is allowed");
    }

    private static void twoArgRefused(JSONObject result) throws Exception {
        GuardedReaderApplication app = arm();
        boolean refused = refused(() ->
            app.registerReceiver(newReceiver(), new IntentFilter(ACTION)));
        result.put("refused", refused).put("nativeRegisterCalls", app.registered.size());
        require(refused, "the two-argument overload must be refused while armed");
        require(app.registered.size() == 0, "a refused registration must not reach the platform");
    }

    private static void wrongRegistrations(JSONObject result) throws Exception {
        GuardedReaderApplication app = arm();
        int before = app.registered.size();
        boolean foreignClass = refused(() ->
            app.registerReceiver(new ForeignReceiver(), new IntentFilter(ACTION), 2));
        boolean foreignAction = refused(() ->
            app.registerReceiver(newReceiver(), new IntentFilter("other.action"), 2));
        boolean wrongFlags = refused(() ->
            app.registerReceiver(newReceiver(), new IntentFilter(ACTION), 4));
        boolean category = refused(() -> {
            IntentFilter filter = new IntentFilter(ACTION);
            filter.addCategory("c");
            app.registerReceiver(newReceiver(), filter, 2);
        });
        boolean dataType = refused(() -> {
            IntentFilter filter = new IntentFilter(ACTION);
            filter.addDataType("text/plain");
            app.registerReceiver(newReceiver(), filter, 2);
        });
        boolean fourArg = refused(() -> app.registerReceiver(newReceiver(),
            new IntentFilter(ACTION), null, new android.os.Handler(null)));
        boolean fiveArg = refused(() -> app.registerReceiver(newReceiver(),
            new IntentFilter(ACTION), null, new android.os.Handler(null), 2));
        boolean lifecycle = refused(() ->
            app.registerActivityLifecycleCallbacks(new ForeignLifecycle()));
        result.put("foreignClass", foreignClass).put("foreignAction", foreignAction)
            .put("wrongFlags", wrongFlags).put("category", category)
            .put("dataType", dataType).put("fourArg", fourArg).put("fiveArg", fiveArg)
            .put("lifecycle", lifecycle).put("nativeRegisterCalls", app.registered.size());
        require(foreignClass && foreignAction && wrongFlags && category && dataType
            && fourArg && fiveArg && lifecycle, "every wrong registration must be refused");
        require(app.registered.size() == before,
            "no refused registration may reach the platform");
    }

    private static void ipcNotDelivered(JSONObject result) throws Exception {
        GuardedReaderApplication app = arm();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Intent inbound = new Intent(ACTION);
        app.lastReceiver.onReceive(app, inbound);
        result.put("delivered", com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver.delivered)
            .put("extrasRead", inbound.extrasRead)
            .put("captureFailed", GuardedReaderApplication.captureFailed());
        require(com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver.delivered == 0,
            "an inbound IPC attempt must never reach the native receiver");
        require(!inbound.extrasRead, "an inbound IPC attempt must never read the extras");
        require(GuardedReaderApplication.captureFailed(),
            "an inbound IPC attempt must fail the capture visibly");
    }

    private static void registrationFailure(JSONObject result) throws Exception {
        GuardedReaderApplication app = arm();
        app.registerFailure = new SecurityException("platform refused");
        boolean refused = refused(() ->
            app.registerReceiver(newReceiver(), new IntentFilter(ACTION), 2));
        JSONObject receipt = GuardedReaderApplication.captureReceipt();
        result.put("refused", refused)
            .put("successful", receipt.optInt("successfulRegistrations"))
            .put("attempted", receipt.optInt("attemptedRegistrations"))
            .put("pendingWrappers", receipt.optInt("pendingWrappers"));
        require(refused, "a platform registration failure must be rethrown");
        require(receipt.optInt("successfulRegistrations") == 0,
            "a failed registration must not be counted as successful");
        require(receipt.optInt("pendingWrappers") == 0,
            "a failed registration must not leave a wrapper owned");
    }

    private static void foreignUnregisterRefused(JSONObject result) throws Exception {
        GuardedReaderApplication app = arm();
        boolean refused = refused(() -> app.unregisterReceiver(new ForeignReceiver()));
        result.put("refused", refused).put("nativeUnregisterCalls", app.unregistered.size());
        require(refused, "a foreign unregistration must be refused");
        require(app.unregistered.size() == 0,
            "a foreign unregistration must not reach the platform");
    }

    private static void failedReleaseRetains(JSONObject result) throws Exception {
        GuardedReaderApplication app = arm();
        app.registerReceiver(newReceiver(), new IntentFilter(ACTION), 2);
        app.unregisterFailure = new RuntimeException("owned removal failed");
        JSONObject first = GuardedReaderApplication.releaseProcessResources();
        app.unregisterFailure = null;
        JSONObject second = GuardedReaderApplication.releaseProcessResources();
        result.put("first", first).put("second", second)
            .put("nativeUnregisterCalls", app.unregistered.size());
        require(!first.optBoolean("closed"), "a failed release must not report closed");
        require(first.optInt("remainingOwnedReceivers") == 1,
            "a failed removal must keep the handle owned");
        require(second.optBoolean("closed"), "the retry must genuinely close the domain");
        require(second.optInt("removedReceivers") == 1,
            "the retry must perform a real platform removal");
        require(app.unregistered.size() == 1,
            "exactly one successful platform removal must happen");
    }

    private static void doubleEndIdempotent(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        JSONObject first = GuardedReaderApplication.endSaveObservation(2000);
        JSONObject second = GuardedReaderApplication.endSaveObservation(0);
        result.put("first", first).put("second", second)
            .put("removeCalls", removeCalls());
        require(first.optInt("events") == 1, "the correlated event must be counted");
        require(second.optBoolean("alreadyClosed"), "a second end must be an idempotent no-op");
        require(removeCalls() == 1, "the observer must be removed exactly once");
        require(!GuardedReaderApplication.captureFailed(), "a clean case must not fail");
    }

    private static void releaseClosesObserver(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        JSONObject receipt = GuardedReaderApplication.captureReceipt();
        result.put("release", release).put("observing", receipt.optBoolean("observing"))
            .put("removeCalls", removeCalls());
        require(release.optBoolean("closed"), "process closure must include the observer");
        require(!receipt.optBoolean("observing"), "no observer may stay attached after closure");
        require(removeCalls() == 1, "process closure must actually remove the observer");
    }

    private static void ownerNotOverwritten(JSONObject result) throws Exception {
        GuardedReaderApplication original = arm();
        GuardedReaderApplication other = new GuardedReaderApplication();
        boolean refused = refused(() ->
            other.registerReceiver(newReceiver(), new IntentFilter(ACTION), 2));
        original.registerReceiver(newReceiver(), new IntentFilter(ACTION), 2);
        result.put("refused", refused).put("originalOwnerCalls", original.registered.size())
            .put("otherOwnerCalls", other.registered.size());
        require(refused, "a non-owner instance must not register");
        require(other.registered.size() == 0, "a non-owner instance must not reach the platform");
        require(original.registered.size() == 1, "the proved owner must still register");
    }

    private static void armRejects(JSONObject result) throws Exception {
        GuardedReaderApplication app = new GuardedReaderApplication();
        boolean nullOwner = refused(() -> GuardedReaderApplication.arm(null, loader()));
        boolean nullLoader = refused(() -> GuardedReaderApplication.arm(app, null));
        GuardedReaderApplication.arm(app, loader());
        GuardedReaderApplication other = new GuardedReaderApplication();
        boolean rearm = refused(() -> GuardedReaderApplication.arm(other, loader()));
        result.put("nullOwner", nullOwner).put("nullLoader", nullLoader).put("rearm", rearm);
        require(nullOwner && nullLoader && rearm, "arm must reject an invalid or foreign owner");
    }

    private static void foreignEventFails(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://foreign", "http://foreign/c1");
        deliver("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        JSONObject end = GuardedReaderApplication.endSaveObservation(2000);
        result.put("end", end).put("captureFailed", GuardedReaderApplication.captureFailed())
            .put("removeCalls", removeCalls());
        require(end.optInt("foreignEvents") == 1, "a foreign event must be recorded");
        require(end.optInt("events") == 2, "a duplicate correlated event must be recorded");
        require(end.optBoolean("failed"), "a foreign or duplicate event must fail the case");
        require(GuardedReaderApplication.captureFailed(), "the capture must be marked failed");
        require(removeCalls() == 1, "the observer must still be removed on a failed case");
    }

    private static void abandonedRegistration(JSONObject result) throws Exception {
        arm();
        android.os.Handler.hold();
        final Throwable[] failure = {null};
        Thread caller = new Thread(() -> {
            try {
                GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
            } catch (Throwable error) {
                failure[0] = error;
            }
        }, "caller");
        caller.start();
        require(android.os.Handler.awaitQueued(2000), "the main registration must be queued");
        caller.interrupt();
        caller.join(2000);
        require(!caller.isAlive(), "the interrupted caller must stop");
        JSONObject closed = GuardedReaderApplication.releaseProcessResources();
        android.os.Handler.flush();
        require(android.os.Handler.awaitIdle(2000), "the held work must flush");
        JSONObject receipt = GuardedReaderApplication.captureReceipt();
        result.put("callerFailure", failure[0] == null ? JSONObject.NULL : failure[0].toString())
            .put("closed", closed).put("observing", receipt.optBoolean("observing"))
            .put("observeCalls", observeCalls());
        require(failure[0] instanceof InterruptedException,
            "the interrupted caller must observe the interruption");
        require(!receipt.optBoolean("observing"),
            "abandoned queued work must never attach an observer after closure");
        require(observeCalls() == 0, "abandoned queued work must never reach the observable");
    }

    private static void twoSavedCases(JSONObject result) throws Exception {
        GuardedReaderApplication app = arm();
        app.registerReceiver(newReceiver(), new IntentFilter(ACTION), 2);
        JSONObject first = savedCase("http://book/1", "http://book/1/c1");
        JSONObject second = savedCase("http://book/2", "http://book/2/c1");
        JSONObject receipt = GuardedReaderApplication.captureReceipt();
        result.put("first", first).put("second", second)
            .put("armedAfterBoth", receipt.optBoolean("armed"))
            .put("observing", receipt.optBoolean("observing"))
            .put("nativeRegisterCalls", app.registered.size());
        require(first.optInt("events") == 1 && second.optInt("events") == 1,
            "each saved case must observe its own event");
        require(receipt.optBoolean("armed"), "the guard must stay armed across both cases");
        require(!receipt.optBoolean("observing"), "each case must close its own observer");
        require(app.registered.size() == 1,
            "the process registration must not be re-created per case");
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        require(release.optBoolean("closed"), "the final release must close the domain");
    }

    // --- helpers ----------------------------------------------------------

    private static JSONObject savedCase(String bookUrl, String chapterUrl) throws Exception {
        GuardedReaderApplication.beginSaveObservation(bookUrl, chapterUrl);
        deliver(bookUrl, chapterUrl);
        return GuardedReaderApplication.endSaveObservation(2000);
    }

    private static GuardedReaderApplication arm() {
        GuardedReaderApplication app = new GuardedReaderApplication();
        GuardedReaderApplication.arm(app, loader());
        return app;
    }

    private static ClassLoader loader() {
        return GuardedReaderApplicationTest.class.getClassLoader();
    }

    private static com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver newReceiver() {
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver.delivered = 0;
        return new com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver();
    }

    private static Object liveObservable() throws Exception {
        return Class.forName("com.jeremyliao.liveeventbus.LiveEventBus")
            .getMethod("get", String.class, Class.class)
            .invoke(null, GuardedReaderApplication.SAVE_CONTENT_TAG, Class.forName("kotlin.Pair"));
    }

    private static void deliver(String bookUrl, String chapterUrl) throws Exception {
        Object observable = liveObservable();
        Object pair = Class.forName("kotlin.Pair")
            .getConstructor(Object.class, Object.class)
            .newInstance(new FakeBook(bookUrl), new FakeChapter(chapterUrl));
        java.lang.reflect.Method deliver =
            observable.getClass().getDeclaredMethod("deliver", Object.class);
        deliver.setAccessible(true);
        deliver.invoke(observable, pair);
    }

    private static int counter(String name) throws Exception {
        Object observable = liveObservable();
        java.lang.reflect.Field field = observable.getClass().getDeclaredField(name);
        field.setAccessible(true);
        return (Integer) field.get(observable);
    }

    private static int observeCalls() throws Exception { return counter("observeCalls"); }

    private static int removeCalls() throws Exception { return counter("removeCalls"); }

    private interface Refusal {
        void run() throws Exception;
    }

    private static boolean refused(Refusal action) {
        try {
            action.run();
            return false;
        } catch (SecurityException expected) {
            return true;
        } catch (Exception other) {
            throw new AssertionError("unexpected failure: " + other, other);
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
