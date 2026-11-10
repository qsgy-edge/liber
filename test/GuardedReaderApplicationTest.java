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
        @Override public void onActivityCreated(android.app.Activity activity,
                android.os.Bundle state) {}
        @Override public void onActivityStarted(android.app.Activity activity) {}
        @Override public void onActivityResumed(android.app.Activity activity) {}
        @Override public void onActivityPaused(android.app.Activity activity) {}
        @Override public void onActivityStopped(android.app.Activity activity) {}
        @Override public void onActivitySaveInstanceState(android.app.Activity activity,
                android.os.Bundle state) {}
        @Override public void onActivityDestroyed(android.app.Activity activity) {}
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
            case "wrong-loader-refused": wrongLoaderRefused(result); break;
            case "save-valid": saveValid(result); break;
            case "save-missing": saveMissing(result); break;
            case "save-duplicate": saveDuplicate(result); break;
            case "save-foreign": saveForeign(result); break;
            case "save-callback-error": saveCallbackError(result); break;
            case "save-malformed": saveMalformed(result); break;
            case "save-off-main": saveOffMain(result); break;
            case "save-idempotent": saveIdempotent(result); break;
            case "save-invalid-repeat": saveInvalidRepeat(result); break;
            case "save-end-before-begin": saveEndBeforeBegin(result); break;
            case "save-overlap": saveOverlap(result); break;
            case "save-stale-proxy": saveStaleProxy(result); break;
            case "save-two-cases": saveTwoCases(result); break;
            case "loaded-identity": loadedIdentity(result); break;
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
        // The base returns and records, so this only passes when the guard's own
        // overrides refuse: the fake must never see the launch.
        int before = GuardedReaderApplication.launchAttempts();
        boolean first = false;
        boolean second = false;
        try { app.startActivity(new Intent("x")); } catch (SecurityException expected) { first = true; }
        try { app.startActivity(new Intent("x"), new android.os.Bundle()); }
        catch (SecurityException expected) { second = true; }
        result.put("bothLaunchRefusals", first && second)
            .put("launchAttempts", GuardedReaderApplication.launchAttempts() - before)
            .put("baseLaunches", app.launched.size());
        require(app.launched.isEmpty(),
            "the base activity launch must never be reached in any mode");
        require(GuardedReaderApplication.launchAttempts() - before == 2,
            "both guard activity refusals must be counted");
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
        // A second correlated delivery is a duplicate, not a foreign event: the
        // two causes are counted separately.
        require(end.optInt("foreignEvents") == 1, "a foreign event must be recorded");
        require(end.optInt("events") == 1, "exactly one correlated event is counted");
        require(end.optInt("duplicates") == 1, "a duplicate correlated event must be recorded");
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

    /**
     * A same-FQCN receiver from another loader is a different class and must be
     * refused before the base registration effect, leaving the owner intact.
     */
    private static void wrongLoaderRefused(JSONObject result) throws Exception {
        GuardedReaderApplication app = arm();
        java.io.File overlay = new java.io.File(
            com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver.class
                .getProtectionDomain().getCodeSource().getLocation().toURI());
        // Child-first for the receiver package, so the same FQCN really becomes a
        // distinct class from a distinct loader.
        java.net.URLClassLoader foreign = new java.net.URLClassLoader(
            new java.net.URL[] {overlay.toURI().toURL()}, loader()) {
            @Override
            protected Class<?> loadClass(String name, boolean resolve)
                    throws ClassNotFoundException {
                if (name.startsWith("com.jeremyliao.liveeventbus.ipc.receiver.")) {
                    Class<?> found = findLoadedClass(name);
                    if (found == null) found = findClass(name);
                    if (resolve) resolveClass(found);
                    return found;
                }
                return super.loadClass(name, resolve);
            }
        };
        Class<?> sameName = Class.forName(
            "com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver", true, foreign);
        Object receiver = sameName.getConstructor().newInstance();
        boolean foreignClass = sameName != newReceiver().getClass();
        boolean refused = false;
        try {
            app.registerReceiver((android.content.BroadcastReceiver) receiver,
                new IntentFilter(ACTION), 2);
        } catch (SecurityException expected) {
            refused = true;
        }
        result.put("foreignClassDistinct", foreignClass)
            .put("refused", refused)
            .put("baseRegistrations", app.registered.size())
            .put("captureFailed", GuardedReaderApplication.captureFailed());
        require(foreignClass, "the foreign loader must really produce a distinct class");
        require(refused, "a same-named receiver from another loader must be refused");
        require(app.registered.isEmpty(),
            "the wrong-loader registration must not reach the base effect");
        require(GuardedReaderApplication.captureFailed(),
            "the wrong-loader attempt must fail the capture");
        // The exact owner is still intact after the refusal.
        app.registerReceiver(newReceiver(), new IntentFilter(ACTION), 2);
        require(app.registered.size() == 1,
            "the exact owner must still register after a wrong-loader refusal");
        foreign.close();
    }

    /**
     * Proves which guard bytes actually loaded and emits their encoded bytes.
     *
     * <p>The code source is the SDK-compiled directory, and each emitted class
     * is read back from that location so the retained bytes are the executed ones.
     */
    private static void loadedIdentity(JSONObject result) throws Exception {
        java.security.CodeSource source =
            GuardedReaderApplication.class.getProtectionDomain().getCodeSource();
        java.io.File root = new java.io.File(source.getLocation().toURI());
        result.put("codeSource", root.getAbsolutePath());
        java.io.File directory = new java.io.File(root, "io/liber/oracle/nested");
        JSONObject hashes = new JSONObject();
        JSONObject encoded = new JSONObject();
        java.io.File[] files = directory.listFiles();
        java.util.Arrays.sort(files);
        for (java.io.File file : files) {
            String name = file.getName();
            if (!name.startsWith("GuardedReaderApplication") || !name.endsWith(".class")) continue;
            byte[] bytes = java.nio.file.Files.readAllBytes(file.toPath());
            hashes.put(name, sha256(bytes));
            encoded.put(name, java.util.Base64.getEncoder().encodeToString(bytes));
        }
        result.put("classSha256", hashes).put("classBytesBase64", encoded)
            .put("classCount", hashes.length());
        require(hashes.has("GuardedReaderApplication.class"),
            "the loaded guard class must be read back from its code source");
        require(hashes.length() >= 2,
            "the guard and its inner classes must be retained");
    }

    private static String sha256(byte[] bytes) throws Exception {
        StringBuilder text = new StringBuilder();
        for (byte value : java.security.MessageDigest.getInstance("SHA-256").digest(bytes)) {
            text.append(String.format("%02x", value & 255));
        }
        return text.toString();
    }

    // --- A2 save-event controls -------------------------------------------

    private static Object typedPair(String bookUrl, String chapterUrl) throws Exception {
        return pair(new io.legado.app.data.entities.Book(bookUrl),
            new io.legado.app.data.entities.BookChapter(chapterUrl));
    }

    private static void saveValid(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        JSONObject end = GuardedReaderApplication.endSaveObservation(2000);
        result.put("end", end).put("removeCalls", removeCalls())
            .put("captureFailed", GuardedReaderApplication.captureFailed());
        require(end.optInt("events") == 1, "exactly one correlated event");
        require(end.optInt("duplicates") == 0 && end.optInt("foreignEvents") == 0
            && end.optInt("callbackErrors") == 0 && end.optInt("offMainEvents") == 0
            && end.optInt("malformedEvents") == 0, "no invalid cause");
        require(end.getJSONObject("removal").optBoolean("removed"),
            "the real removal must be acknowledged");
        require(end.getJSONObject("removal").optBoolean("onMain"),
            "the removal must execute on MAIN");
        require(removeCalls() == 1, "exactly one removal");
        require(!GuardedReaderApplication.captureFailed(), "a clean case must not fail");
    }

    private static void saveMissing(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        JSONObject end = GuardedReaderApplication.endSaveObservation(200);
        result.put("end", end).put("removeCalls", removeCalls());
        require(end.optInt("events") == 0, "no correlated event arrived");
        require(end.optBoolean("failed"), "a missing event must fail the case");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
        require(removeCalls() == 1, "the owned observer must still be removed");
    }

    private static void saveDuplicate(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        JSONObject end = GuardedReaderApplication.endSaveObservation(2000);
        result.put("end", end).put("removeCalls", removeCalls());
        require(end.optInt("events") == 1, "one correlated event is counted");
        require(end.optInt("duplicates") == 1, "the duplicate is recorded");
        require(end.optInt("foreignEvents") == 0, "a duplicate is not a foreign event");
        require(end.optBoolean("failed"), "a duplicate must fail the case");
        require(removeCalls() == 1, "the observer must still be removed");
    }

    private static void saveForeign(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://other", "http://other/c1");
        JSONObject end = GuardedReaderApplication.endSaveObservation(200);
        result.put("end", end).put("removeCalls", removeCalls());
        require(end.optInt("events") == 0 && end.optInt("foreignEvents") == 1,
            "a foreign-only delivery is a foreign event");
        require(end.optBoolean("failed"), "a foreign event must fail the case");
        require(removeCalls() == 1, "the observer must still be removed");
    }

    /** A genuine approved-type payload whose getter throws. */
    public static final class ThrowingBook extends io.legado.app.data.entities.Book {
        public ThrowingBook() { super("http://book/1"); }
        @Override public String getBookUrl() {
            throw new IllegalStateException("BOOK_GETTER_FAILURE");
        }
    }

    private static void saveCallbackError(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliverOnMain(pair(new ThrowingBook(),
            new io.legado.app.data.entities.BookChapter("http://book/1/c1")));
        JSONObject end = GuardedReaderApplication.endSaveObservation(200);
        result.put("end", end).put("removeCalls", removeCalls());
        require(end.optInt("callbackErrors") == 1, "the callback error is recorded");
        require(end.optInt("events") == 0, "a throwing getter yields no correlated event");
        require(end.optBoolean("failed"), "a callback error must fail the case");
        require(removeCalls() == 1, "the observer must still be removed");
    }

    /** A duck-typed impostor: same getter names, not the approved types. */
    public static final class ImpostorPair {
        public Object getFirst() { ImpostorBook.executed = true; return new ImpostorBook(); }
        public Object getSecond() { return new ImpostorChapter(); }
    }

    public static final class ImpostorBook {
        public static boolean executed;
        public String getBookUrl() { executed = true; return "http://book/1"; }
    }

    public static final class ImpostorChapter {
        public static boolean executed;
        public String getUrl() { executed = true; return "http://book/1/c1"; }
    }

    private static void saveMalformed(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        ImpostorBook.executed = false;
        ImpostorChapter.executed = false;
        deliverOnMain(new ImpostorPair());
        JSONObject end = GuardedReaderApplication.endSaveObservation(200);
        result.put("end", end).put("removeCalls", removeCalls())
            .put("impostorGetterExecuted", ImpostorBook.executed || ImpostorChapter.executed);
        require(!ImpostorBook.executed && !ImpostorChapter.executed,
            "an impostor getter must never execute");
        require(end.optInt("malformedEvents") == 1, "the malformed payload is recorded");
        require(end.optInt("events") == 0, "a malformed payload is not a correlated event");
        require(end.optBoolean("failed"), "a malformed payload must fail the case");
        require(removeCalls() == 1, "the observer must still be removed");
    }

    private static void saveOffMain(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliverOffMain(typedPair("http://book/1", "http://book/1/c1"));
        JSONObject end = GuardedReaderApplication.endSaveObservation(200);
        result.put("end", end).put("removeCalls", removeCalls());
        require(end.optInt("offMainEvents") == 1, "the off-main delivery is recorded");
        require(end.optInt("events") == 0, "an off-main delivery is not a valid event");
        require(end.optBoolean("failed"), "an off-main delivery must fail the case");
        require(removeCalls() == 1, "the observer must still be removed");
    }

    private static void saveIdempotent(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        JSONObject first = GuardedReaderApplication.endSaveObservation(2000);
        JSONObject second = GuardedReaderApplication.endSaveObservation(0);
        result.put("first", first).put("second", second).put("removeCalls", removeCalls());
        require(first.optInt("events") == 1, "the first close counts the event");
        require(second.optBoolean("alreadyClosed") && second.optBoolean("removed"),
            "the repeat is an acknowledged idempotent close");
        require(!second.optBoolean("failed"), "a clean repeat stays clean");
        require(removeCalls() == 1, "the observer is removed exactly once");
        require(!GuardedReaderApplication.captureFailed(), "a clean case must not fail");
    }

    private static void saveInvalidRepeat(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        JSONObject first = GuardedReaderApplication.endSaveObservation(200);
        JSONObject second = GuardedReaderApplication.endSaveObservation(0);
        result.put("first", first).put("second", second).put("removeCalls", removeCalls());
        require(first.optBoolean("failed"), "the invalid observation fails");
        require(second.optBoolean("alreadyClosed"), "the repeat is acknowledged");
        require(second.optBoolean("failed"),
            "the repeat must not erase the earlier failure");
        require(second.optInt("events") == 0, "no invented event appears on the repeat");
        require(removeCalls() == 1, "the observer is removed exactly once");
    }

    private static void saveEndBeforeBegin(JSONObject result) throws Exception {
        arm();
        JSONObject end = GuardedReaderApplication.endSaveObservation(0);
        result.put("end", end).put("removeCalls", removeCalls());
        require(!end.optBoolean("removed"),
            "an end with no successful begin is not an invented removal");
        require("never-registered".equals(end.getJSONObject("removal").optString("reason")),
            "the removal reports the never-registered reason");
        require(removeCalls() == 0, "nothing was registered, so nothing is removed");
    }

    private static void saveOverlap(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        int observesBefore = observeCalls();
        boolean refused = false;
        try {
            GuardedReaderApplication.beginSaveObservation("http://book/2", "http://book/2/c1");
        } catch (IllegalStateException expected) {
            refused = true;
        }
        int observesAfter = observeCalls();
        deliver("http://book/1", "http://book/1/c1");
        JSONObject end = GuardedReaderApplication.endSaveObservation(2000);
        result.put("refused", refused).put("observesBefore", observesBefore)
            .put("observesAfter", observesAfter).put("end", end)
            .put("removeCalls", removeCalls());
        require(refused, "an overlapping begin must be refused");
        require(observesAfter == observesBefore,
            "the refused begin must add no observe effect");
        require(end.optInt("events") == 1,
            "the original observation keeps its own counters");
        require(!end.optBoolean("failed"), "the original observation can still close cleanly");
        require(removeCalls() == 1, "the original observer is removed exactly once");
    }

    private static void saveStaleProxy(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        // Capture the live observer before the close clears the field.
        Object staleObserver = staleObserver();
        deliver("http://book/1", "http://book/1/c1");
        GuardedReaderApplication.endSaveObservation(2000);
        // A second, healthy observation under the same armed lifetime.
        GuardedReaderApplication.beginSaveObservation("http://book/2", "http://book/2/c1");
        // The retained proxy from case 1 is invoked during case 2.
        invokeOnMain(staleObserver, pair(new io.legado.app.data.entities.Book("http://book/1"),
            new io.legado.app.data.entities.BookChapter("http://book/1/c1")));
        deliver("http://book/2", "http://book/2/c1");
        JSONObject end = GuardedReaderApplication.endSaveObservation(2000);
        result.put("end", end).put("removeCalls", removeCalls());
        // The stale proxy is bound to its own observation, so its delivery is
        // isolated from the new case's counters while still failing the capture.
        require(end.optInt("events") == 1,
            "the stale proxy must not be counted in the new observation");
        require(end.optInt("foreignEvents") == 0 && end.optInt("duplicates") == 0,
            "the stale delivery must not corrupt the new case's counters");
        require(!end.optBoolean("failed"),
            "the new case's own facts stay clean");
        require(GuardedReaderApplication.captureFailed(),
            "the stale delivery must fail the capture");
    }

    private static void saveTwoCases(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        JSONObject first = GuardedReaderApplication.endSaveObservation(2000);
        GuardedReaderApplication.beginSaveObservation("http://book/2", "http://book/2/c1");
        deliver("http://book/2", "http://book/2/c1");
        JSONObject second = GuardedReaderApplication.endSaveObservation(2000);
        result.put("first", first).put("second", second).put("removeCalls", removeCalls());
        require(first.optInt("events") == 1 && !first.optBoolean("failed"),
            "case 1 is clean");
        require(second.optInt("events") == 1 && !second.optBoolean("failed"),
            "case 2 is clean and independent");
        require(second.optInt("foreignEvents") == 0,
            "case 1's event is not counted in case 2");
        require(removeCalls() == 2, "each case removes its own observer");
        require(!GuardedReaderApplication.captureFailed(), "two clean cases do not fail");
    }

    private static Object staleObserver() throws Exception {
        java.lang.reflect.Field field =
            GuardedReaderApplication.class.getDeclaredField("saveObserver");
        field.setAccessible(true);
        return field.get(null);
    }

    private static void invokeOnMain(final Object observer, final Object payload)
            throws Exception {
        final java.util.concurrent.CountDownLatch done =
            new java.util.concurrent.CountDownLatch(1);
        new android.os.Handler(android.os.Looper.getMainLooper()).post(() -> {
            try {
                Class<?> observerInterface =
                    Class.forName("androidx.lifecycle.Observer");
                observerInterface.getMethod("onChanged", Object.class)
                    .invoke(observer, payload);
            } catch (Throwable ignored) {
                // The guard's own recording is the evidence.
            } finally {
                done.countDown();
            }
        });
        done.await(5, java.util.concurrent.TimeUnit.SECONDS);
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

    /** Delivers the approved typed payload on the controlled MAIN thread. */
    private static void deliver(String bookUrl, String chapterUrl) throws Exception {
        deliverOnMain(pair(new io.legado.app.data.entities.Book(bookUrl),
            new io.legado.app.data.entities.BookChapter(chapterUrl)));
    }

    /** Runs one real delivery on the controlled MAIN thread and waits for it. */
    private static void deliverOnMain(Object payload) throws Exception {
        final java.util.concurrent.CountDownLatch done =
            new java.util.concurrent.CountDownLatch(1);
        final Throwable[] failure = {null};
        boolean posted = new android.os.Handler(android.os.Looper.getMainLooper()).post(() -> {
            try {
                deliverPayload(payload);
            } catch (Throwable error) {
                failure[0] = error;
            } finally {
                done.countDown();
            }
        });
        if (!posted || !done.await(5, java.util.concurrent.TimeUnit.SECONDS)) {
            throw new IllegalStateException("the main-thread delivery did not run");
        }
        if (failure[0] != null) throw new IllegalStateException(failure[0]);
    }

    /** Delivers from the calling thread, for the deliberate off-main control. */
    private static void deliverOffMain(Object payload) throws Exception {
        deliverPayload(payload);
    }

    private static Object pair(Object first, Object second) throws Exception {
        return Class.forName("kotlin.Pair")
            .getConstructor(Object.class, Object.class)
            .newInstance(first, second);
    }

    private static void deliverPayload(Object payload) throws Exception {
        Object observable = liveObservable();
        java.lang.reflect.Method deliver =
            observable.getClass().getDeclaredMethod("deliver", Object.class);
        deliver.setAccessible(true);
        deliver.invoke(observable, payload);
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
