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
            case "save-null-payload": saveNullPayload(result); break;
            case "save-null-book": saveNullBook(result); break;
            case "save-null-chapter": saveNullChapter(result); break;
            case "save-wrong-book": saveWrongBook(result); break;
            case "save-wrong-chapter": saveWrongChapter(result); break;
            case "save-receipt-copy": saveReceiptCopy(result); break;
            case "save-stale-after-close": saveStaleAfterClose(result); break;
            case "resource-receiver-normal": resourceReceiverNormal(result); break;
            case "resource-receiver-acquire-before": resourceReceiverAcquireBefore(result); break;
            case "resource-receiver-acquire-after": resourceReceiverAcquireAfter(result); break;
            case "resource-receiver-remove-before-retry": resourceReceiverRemoveBeforeRetry(result); break;
            case "resource-receiver-remove-after": resourceReceiverRemoveAfter(result); break;
            case "resource-receiver-early-close": resourceReceiverEarlyClose(result); break;
            case "resource-receiver-foreign-owner": resourceReceiverForeignOwner(result); break;
            case "resource-lifecycle-normal": resourceLifecycleNormal(result); break;
            case "resource-lifecycle-acquire-before": resourceLifecycleAcquireBefore(result); break;
            case "resource-lifecycle-acquire-after": resourceLifecycleAcquireAfter(result); break;
            case "resource-lifecycle-remove-before-retry": resourceLifecycleRemoveBeforeRetry(result); break;
            case "resource-lifecycle-remove-after": resourceLifecycleRemoveAfter(result); break;
            case "resource-lifecycle-early-close": resourceLifecycleEarlyClose(result); break;
            case "resource-lifecycle-foreign-owner": resourceLifecycleForeignOwner(result); break;
            case "resource-observer-normal": resourceObserverNormal(result); break;
            case "resource-observer-acquire-before": resourceObserverAcquireBefore(result); break;
            case "resource-observer-acquire-after": resourceObserverAcquireAfter(result); break;
            case "resource-observer-remove-before-retry": resourceObserverRemoveBeforeRetry(result); break;
            case "resource-observer-remove-after": resourceObserverRemoveAfter(result); break;
            case "resource-observer-early-close": resourceObserverEarlyClose(result); break;
            case "resource-cleanup-errors": resourceCleanupErrors(result); break;
            case "boundary-exact-registration": boundaryExactRegistration(result); break;
            case "boundary-filter-empty": boundaryFilter(result, "boundary-filter-empty"); break;
            case "boundary-filter-action": boundaryFilter(result, "boundary-filter-action"); break;
            case "boundary-filter-extra-action": boundaryFilter(result, "boundary-filter-extra-action"); break;
            case "boundary-filter-type": boundaryFilter(result, "boundary-filter-type"); break;
            case "boundary-filter-scheme": boundaryFilter(result, "boundary-filter-scheme"); break;
            case "boundary-filter-category": boundaryFilter(result, "boundary-filter-category"); break;
            case "boundary-filter-authority": boundaryFilter(result, "boundary-filter-authority"); break;
            case "boundary-filter-path": boundaryFilter(result, "boundary-filter-path"); break;
            case "boundary-filter-ssp": boundaryFilter(result, "boundary-filter-ssp"); break;
            case "boundary-filter-subclass": boundaryFilter(result, "boundary-filter-subclass"); break;
            case "boundary-flags-zero": boundaryRoute(result, "boundary-flags-zero"); break;
            case "boundary-flags-other": boundaryRoute(result, "boundary-flags-other"); break;
            case "boundary-overload2": boundaryRoute(result, "boundary-overload2"); break;
            case "boundary-overload4": boundaryRoute(result, "boundary-overload4"); break;
            case "boundary-overload5": boundaryRoute(result, "boundary-overload5"); break;
            case "boundary-null-receiver": boundaryRoute(result, "boundary-null-receiver"); break;
            case "boundary-null-filter": boundaryRoute(result, "boundary-null-filter"); break;
            case "boundary-closed-arm": boundaryClosed(result, "boundary-closed-arm"); break;
            case "boundary-closed-receiver": boundaryClosed(result, "boundary-closed-receiver"); break;
            case "boundary-closed-lifecycle": boundaryClosed(result, "boundary-closed-lifecycle"); break;
            case "boundary-closed-observer": boundaryClosed(result, "boundary-closed-observer"); break;
            case "boundary-close-before-reserve": boundaryCloseBeforeReserve(result); break;
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
        // The handle is reserved before the effect, so a throwing registration
        // keeps it owned for a real removal instead of losing it.
        require(receipt.optInt("pendingWrappers") == 1,
            "a failed registration must retain its reserved wrapper");
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
        JSONObject begin =
            GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        JSONObject end = GuardedReaderApplication.endSaveObservation(2000);
        result.put("begin", begin).put("end", end).put("observeCalls", observeCalls())
            .put("removeCalls", removeCalls())
            .put("captureFailed", GuardedReaderApplication.captureFailed());
        require(begin.optBoolean("registered") && begin.optBoolean("onMain"),
            "the begin must register on MAIN");
        require(observeCalls() == 1, "exactly one observe call");
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

    /**
     * A real approved-type Book carrying the artificial read-failure hook. The
     * selected target getter is a plain final field read; this injected fault is
     * a host reflection-boundary control, not native getter reachability.
     */
    private static void saveCallbackError(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        io.legado.app.data.entities.Book faulted =
            new io.legado.app.data.entities.Book("http://book/1");
        RuntimeException original = new IllegalStateException("BOOK_GETTER_FAILURE",
            new IllegalArgumentException("BOOK_GETTER_NESTED"));
        original.addSuppressed(new IllegalStateException("BOOK_GETTER_SUPPRESSED"));
        faulted.readFailure = original;
        deliverOnMain(pair(faulted,
            new io.legado.app.data.entities.BookChapter("http://book/1/c1")));
        JSONObject end = GuardedReaderApplication.endSaveObservation(200);
        String failures = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").toString();
        result.put("end", end).put("removeCalls", removeCalls())
            .put("failures", failures);
        require(end.optInt("callbackErrors") == 1, "the callback error is recorded");
        require(end.optInt("events") == 0, "a throwing getter yields no correlated event");
        require(end.optBoolean("failed"), "a callback error must fail the case");
        require(removeCalls() == 1, "the observer must still be removed");
        // The original reflection target and its graph survive into the evidence.
        require(failures.contains("BOOK_GETTER_FAILURE"),
            "the original callback cause must be retained");
        require(failures.contains("BOOK_GETTER_NESTED"),
            "the nested cause must be retained");
        require(failures.contains("BOOK_GETTER_SUPPRESSED"),
            "the suppressed error must be retained");
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

    /** A genuine approved Pair carrying a wrong-typed chapter. */
    public static final class DuckChapter {
        static int reads;
        public String getUrl() { reads++; return "http://book/1/c1"; }
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

    /**
     * Invokes a retained observer on MAIN and acknowledges the executed call.
     *
     * <p>The post result and the timed await are both required, and an unexpected
     * reflection failure is propagated rather than swallowed.
     */
    private static void invokeOnMain(final Object observer, final Object payload)
            throws Exception {
        final java.util.concurrent.CountDownLatch done =
            new java.util.concurrent.CountDownLatch(1);
        final Throwable[] failure = {null};
        boolean posted = new android.os.Handler(android.os.Looper.getMainLooper()).post(() -> {
            try {
                Class<?> observerInterface =
                    Class.forName("androidx.lifecycle.Observer");
                observerInterface.getMethod("onChanged", Object.class)
                    .invoke(observer, payload);
            } catch (Throwable error) {
                failure[0] = error;
            } finally {
                done.countDown();
            }
        });
        if (!posted || !done.await(5, java.util.concurrent.TimeUnit.SECONDS)) {
            throw new IllegalStateException("the retained-callback delivery was not acknowledged");
        }
        if (failure[0] != null) {
            throw new IllegalStateException("the retained-callback delivery failed", failure[0]);
        }
    }


    /**
     * One owned wrong input in its own armed lifetime: the payload is malformed,
     * no correlated event is accepted, and the owned observer is still removed.
     */
    private static void saveOneWrongInput(JSONObject result, String mode, Object payload)
            throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliverOnMain(payload);
        JSONObject end = GuardedReaderApplication.endSaveObservation(200);
        result.put("mode", mode).put("end", end).put("removeCalls", removeCalls())
            .put("impostorGetterExecuted", ImpostorBook.executed)
            .put("duckChapterReads", DuckChapter.reads);
        require(end.optInt("malformedEvents") == 1, mode + ": the input is malformed");
        require(end.optInt("events") == 0, mode + ": no correlated event from a wrong input");
        require(end.optBoolean("failed"), mode + ": a wrong input must fail the case");
        require(end.getJSONObject("removal").optBoolean("removed"),
            mode + ": the owned observer is still removed");
        require(removeCalls() == 1, mode + ": exactly one removal");
        require(!ImpostorBook.executed && DuckChapter.reads == 0,
            mode + ": no arbitrary wrong getter may execute");
    }

    private static void saveNullPayload(JSONObject result) throws Exception {
        ImpostorBook.executed = false;
        DuckChapter.reads = 0;
        saveOneWrongInput(result, "null-payload", null);
    }

    private static void saveNullBook(JSONObject result) throws Exception {
        ImpostorBook.executed = false;
        DuckChapter.reads = 0;
        saveOneWrongInput(result, "null-book",
            pair(null, new io.legado.app.data.entities.BookChapter("http://book/1/c1")));
    }

    private static void saveNullChapter(JSONObject result) throws Exception {
        ImpostorBook.executed = false;
        DuckChapter.reads = 0;
        saveOneWrongInput(result, "null-chapter",
            pair(new io.legado.app.data.entities.Book("http://book/1"), null));
    }

    private static void saveWrongBook(JSONObject result) throws Exception {
        ImpostorBook.executed = false;
        DuckChapter.reads = 0;
        saveOneWrongInput(result, "wrong-book",
            pair(new ImpostorBook(),
                new io.legado.app.data.entities.BookChapter("http://book/1/c1")));
    }

    private static void saveWrongChapter(JSONObject result) throws Exception {
        ImpostorBook.executed = false;
        DuckChapter.reads = 0;
        saveOneWrongInput(result, "wrong-chapter",
            pair(new io.legado.app.data.entities.Book("http://book/1"), new DuckChapter()));
    }

    /**
     * A caller editing the public repeat receipt must not mutate the cached
     * first-close facts, so the next return and the real close proof stand.
     */
    private static void saveReceiptCopy(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        JSONObject first = GuardedReaderApplication.endSaveObservation(2000);
        JSONObject repeat = GuardedReaderApplication.endSaveObservation(0);
        String firstLast = first.getJSONObject("lastEvent").toString();
        String firstRemoval = first.getJSONObject("removal").toString();
        // Edit only the returned public repeat receipt, root and nested.
        repeat.put("events", 99);
        repeat.getJSONObject("lastEvent").put("bookUrl", "http://mutated");
        repeat.getJSONObject("removal").put("removed", false);
        JSONObject again = GuardedReaderApplication.endSaveObservation(0);
        result.put("first", first).put("repeat", repeat).put("again", again)
            .put("removeCalls", removeCalls());
        require(again.optInt("events") == 1, "the cached event count is unchanged");
        require(again.getJSONObject("lastEvent").toString().equals(firstLast),
            "the cached lastEvent is unchanged by caller mutation");
        require(again.getJSONObject("removal").toString().equals(firstRemoval),
            "the cached removal is unchanged by caller mutation");
        require(again.getJSONObject("removal").optBoolean("removed"),
            "the real removal acknowledgement stands");
        require(again.optBoolean("alreadyClosed") && again.optBoolean("removed"),
            "the real close proof still holds");
        require(removeCalls() == 1, "exactly one real removal");
    }

    /**
     * Two healthy cases under one armed process; after case 2 closes, both the
     * retained case 1 proxy and the just-closed case 2 proxy run on MAIN. Each
     * fails the process capture, and case 2's frozen terminal facts stand.
     */
    private static void saveStaleAfterClose(JSONObject result) throws Exception {
        arm();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        Object case1 = staleObserver();
        deliver("http://book/1", "http://book/1/c1");
        JSONObject firstClose = GuardedReaderApplication.endSaveObservation(2000);
        GuardedReaderApplication.beginSaveObservation("http://book/2", "http://book/2/c1");
        Object case2 = staleObserver();
        deliver("http://book/2", "http://book/2/c1");
        JSONObject secondClose = GuardedReaderApplication.endSaveObservation(2000);
        // Both observations are now closed; invoke each retained proxy afterwards.
        invokeOnMain(case1, typedPair("http://book/1", "http://book/1/c1"));
        boolean failedAfterCase1 = GuardedReaderApplication.captureFailed();
        invokeOnMain(case2, typedPair("http://book/2", "http://book/2/c1"));
        JSONObject repeat = GuardedReaderApplication.endSaveObservation(0);
        result.put("firstClose", firstClose).put("secondClose", secondClose)
            .put("repeat", repeat)
            .put("failedAfterCase1", failedAfterCase1)
            .put("captureFailed", GuardedReaderApplication.captureFailed())
            .put("removeCalls", removeCalls());
        require(failedAfterCase1, "the retained case-1 proxy must fail the capture");
        require(GuardedReaderApplication.captureFailed(), "the capture stays failed");
        require(secondClose.optInt("events") == 1 && !secondClose.optBoolean("failed"),
            "case 2 closed cleanly before the stale callbacks");
        require(secondClose.getJSONObject("lastEvent").optString("bookUrl")
            .equals("http://book/2"), "case 2 carries its own identity");
        // The frozen terminal facts survive both late callbacks.
        require(repeat.optInt("events") == 1, "the frozen event count stands");
        require(repeat.optInt("foreignEvents") == 0 && repeat.optInt("duplicates") == 0
            && repeat.optInt("offMainEvents") == 0 && repeat.optInt("malformedEvents") == 0
            && repeat.optInt("callbackErrors") == 0, "no invalid cause appears on the repeat");
        require(repeat.getJSONObject("lastEvent").optString("bookUrl")
            .equals("http://book/2"), "the frozen lastEvent is case 2's");
        require(repeat.getJSONObject("removal").optBoolean("removed"),
            "the genuine single removal stands");
        require(repeat.optBoolean("alreadyClosed") && repeat.optBoolean("removed"),
            "the real close proof still holds");
        require(removeCalls() == 2, "each case removed its own observer exactly once");
    }

    // --- A3 receiver resource ownership -----------------------------------

    private static GuardedReaderApplication armedApp() {
        GuardedReaderApplication app = new GuardedReaderApplication();
        GuardedReaderApplication.arm(app, loader());
        return app;
    }

    private static Object storedWrapper(GuardedReaderApplication app, Object receiver)
            throws Exception {
        java.lang.reflect.Field field =
            GuardedReaderApplication.class.getDeclaredField("wrappers");
        field.setAccessible(true);
        return ((java.util.Map<?, ?>) field.get(null)).get(receiver);
    }

    private static void resourceReceiverNormal(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object wrapper = storedWrapper(app, receiver);
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        result.put("wrapperStored", wrapper != null)
            .put("registerEffects", app.receiverRegisterEffects)
            .put("unregisterEffects", app.receiverUnregisterEffects)
            .put("nativeRemaining", app.nativeReceivers.size())
            .put("release", release);
        require(wrapper != null, "the exact wrapper must be reserved for the receiver");
        require(app.receiverRegisterEffects == 1, "one real registration effect");
        require(app.receiverUnregisterEffects == 1, "one real removal effect");
        require(app.nativeReceivers.isEmpty(), "the native registry is empty after release");
        require(release.optBoolean("closed"), "a clean receiver closes honestly");
        require(!GuardedReaderApplication.captureFailed(), "a clean path must not fail");
    }

    private static void resourceReceiverAcquireBefore(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        RuntimeException fault = new IllegalStateException("RECEIVER_ACQUIRE_BEFORE",
            new IllegalArgumentException("RECEIVER_ACQUIRE_BEFORE_NESTED"));
        fault.addSuppressed(new IllegalStateException("RECEIVER_ACQUIRE_BEFORE_SUPPRESSED"));
        app.receiverRegisterBeforeEffect = fault;
        boolean refused = refused(() ->
            app.registerReceiver(receiver, new IntentFilter(ACTION), 2));
        JSONObject receipt = GuardedReaderApplication.captureReceipt();
        result.put("refused", refused).put("during", app.receiverDuringEffect)
            .put("registerEffects", app.receiverRegisterEffects)
            .put("nativeRemaining", app.nativeReceivers.size())
            .put("failures", receipt.getJSONArray("failures").toString());
        require(refused, "a before-effect fault must be rethrown");
        // The handle was reserved BEFORE the effect, so it is retained.
        require(app.receiverDuringEffect.startsWith("wrappers=1"),
            "the guard must have reserved the wrapper before the effect");
        require(app.receiverRegisterEffects == 0, "no native registration effect happened");
        require(app.nativeReceivers.isEmpty(), "the native registry stays empty");
        require(storedWrapper(app, receiver) != null, "the reserved handle is retained");
        require(GuardedReaderApplication.captureReceipt()
            .optInt("successfulRegistrations") == 0,
            "a before-effect throw must not be acknowledged as successful");
        require(io.liber.oracle.nested.BoundaryInspection.invokedReceiver
            == storedWrapper(app, receiver),
            "the boundary saw the exact reserved wrapper as its native argument");
        require(io.liber.oracle.nested.BoundaryInspection.invokedInstance == app,
            "the boundary ran on the exact armed instance");
        require(io.liber.oracle.nested.BoundaryInspection.reservedWrapper
            == storedWrapper(app, receiver),
            "the reserved wrapper is the exact stored wrapper");
        require(io.liber.oracle.nested.BoundaryInspection.wrapperOwned,
            "the exact wrapper is in the owned list during the boundary");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
        require(receipt.getJSONArray("failures").toString().contains("RECEIVER_ACQUIRE_BEFORE"),
            "the original cause must be retained");
        require(receipt.getJSONArray("failures").toString()
            .contains("RECEIVER_ACQUIRE_BEFORE_NESTED"), "the nested cause must be retained");
        require(receipt.getJSONArray("failures").toString()
            .contains("RECEIVER_ACQUIRE_BEFORE_SUPPRESSED"), "the suppressed error is retained");
    }

    private static void resourceReceiverAcquireAfter(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        RuntimeException fault = new IllegalStateException("RECEIVER_ACQUIRE_AFTER");
        app.receiverRegisterAfterEffect = fault;
        boolean refused = refused(() ->
            app.registerReceiver(receiver, new IntentFilter(ACTION), 2));
        Object wrapper = storedWrapper(app, receiver);
        result.put("refused", refused).put("during", app.receiverDuringEffect)
            .put("registerEffects", app.receiverRegisterEffects)
            .put("nativeRemaining", app.nativeReceivers.size())
            .put("wrapperStored", wrapper != null);
        require(refused, "an after-effect fault must be rethrown");
        require(app.receiverRegisterEffects == 1, "the native effect really happened");
        require(app.nativeReceivers.size() == 1, "the native handle is really installed");
        // A throwing registration must never be acknowledged as successful.
        require(GuardedReaderApplication.captureReceipt()
            .optInt("successfulRegistrations") == 0,
            "a throwing registration must not be acknowledged as successful");
        require(wrapper != null, "the reserved handle is not lost");
        // The real final release uses the saved owned list to remove the exact handle.
        app.receiverRegisterAfterEffect = null;
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        result.put("release", release).put("nativeAfter", app.nativeReceivers.size());
        require(app.nativeReceivers.isEmpty(), "the real removal cleaned the native handle");
        require(release.optBoolean("closed"), "the resources honestly close after cleanup");
        require(GuardedReaderApplication.captureFailed(), "the capture failure stays sticky");
    }

    private static void resourceReceiverRemoveBeforeRetry(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        RuntimeException fault = new IllegalStateException("RECEIVER_REMOVE_BEFORE");
        app.receiverUnregisterBeforeEffect = fault;
        boolean refused = faulted(() -> app.unregisterReceiver(receiver)) != null;
        Object wrapper = storedWrapper(app, receiver);
        result.put("refused", refused).put("nativeRemaining", app.nativeReceivers.size())
            .put("wrapperStored", wrapper != null)
            .put("failures", GuardedReaderApplication.captureReceipt()
                .getJSONArray("failures").toString());
        require(refused, "a before-effect removal fault must be rethrown");
        require(app.nativeReceivers.size() == 1, "the native handle is still installed");
        require(wrapper != null, "the guard keeps the handle");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
        // Clear the fault and retry the same handle.
        app.receiverUnregisterBeforeEffect = null;
        app.unregisterReceiver(receiver);
        result.put("nativeAfterRetry", app.nativeReceivers.size())
            .put("unregisterEffects", app.receiverUnregisterEffects);
        require(app.nativeReceivers.isEmpty(), "the retry really removed the handle");
        require(app.receiverUnregisterEffects == 1, "exactly one real removal effect");
        require(storedWrapper(app, receiver) == null, "ownership is cleared after the ack");
    }

    private static void resourceReceiverRemoveAfter(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        RuntimeException fault = new IllegalStateException("RECEIVER_REMOVE_AFTER");
        app.receiverUnregisterAfterEffect = fault;
        boolean refused = faulted(() -> app.unregisterReceiver(receiver)) != null;
        Object wrapper = storedWrapper(app, receiver);
        result.put("refused", refused).put("nativeRemaining", app.nativeReceivers.size())
            .put("wrapperStored", wrapper != null);
        require(refused, "an after-effect removal fault must be rethrown");
        require(app.nativeReceivers.isEmpty(), "the native handle really went away");
        require(wrapper != null, "the guard retains uncertain ownership");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
        // A later unknown-receiver exception is not a successful acknowledgement.
        app.receiverUnregisterAfterEffect = null;
        boolean unknown = faulted(() -> app.unregisterReceiver(receiver)) != null;
        result.put("unknownRejected", unknown)
            .put("nativeAfter", app.nativeReceivers.size());
        require(unknown, "the unknown receiver is rejected by the native contract");
        require(storedWrapper(app, receiver) != null,
            "uncertain ownership is not cleared by an unknown-receiver rejection");
    }

    private static void resourceReceiverEarlyClose(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object wrapper = storedWrapper(app, receiver);
        app.unregisterReceiver(receiver);
        int afterEarly = app.receiverUnregisterEffects;
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        result.put("wrapperStored", wrapper != null).put("afterEarly", afterEarly)
            .put("afterRelease", app.receiverUnregisterEffects).put("release", release);
        require(wrapper != null, "the exact wrapper is stored");
        require(afterEarly == 1, "the early close removed exactly once");
        require(app.receiverUnregisterEffects == 1, "the final release must not remove twice");
        require(app.nativeReceivers.isEmpty(), "the native registry is empty");
    }

    private static void resourceReceiverForeignOwner(JSONObject result) throws Exception {
        GuardedReaderApplication owner = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        owner.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object wrapper = storedWrapper(owner, receiver);
        GuardedReaderApplication foreign = new GuardedReaderApplication();
        int ownerBefore = owner.receiverUnregisterAttempts;
        int ownerEffectsBefore = owner.receiverUnregisterEffects;
        boolean refused = refused(() -> foreign.unregisterReceiver(receiver));
        int ownerAfter = owner.receiverUnregisterAttempts;
        result.put("refused", refused).put("wrapperStored", wrapper != null)
            .put("ownerBefore", ownerBefore).put("ownerAfter", ownerAfter)
            .put("foreignAttempts", foreign.receiverUnregisterAttempts)
            .put("foreignEffects", foreign.receiverUnregisterEffects)
            .put("ownerNative", owner.nativeReceivers.size());
        require(wrapper != null, "the real owner stored the wrapper");
        require(refused, "a foreign owner must be refused");
        // The FOREIGN instance's own native delegate must never be touched.
        require(foreign.receiverUnregisterAttempts == 0,
            "the foreign instance must not attempt a native removal");
        require(foreign.receiverUnregisterEffects == 0,
            "the foreign instance must not effect a native removal");
        require(ownerAfter == ownerBefore,
            "the owner's native counters are unchanged by the refusal");
        require(owner.receiverUnregisterEffects == ownerEffectsBefore,
            "the owner's native effect count is unchanged by the refusal");
        require(owner.nativeReceivers.size() == 1,
            "the exact owner handle is still installed after the refusal");
        // The stored exact owner still removes the correct wrapper.
        owner.unregisterReceiver(receiver);
        result.put("nativeAfter", owner.nativeReceivers.size())
            .put("unregisterEffects", owner.receiverUnregisterEffects);
        require(owner.nativeReceivers.isEmpty(),
            "the exact owner removes the correct wrapper");
        require(owner.receiverUnregisterEffects == 1, "exactly one real removal effect");
    }

    // --- A3 lifecycle resource ownership ----------------------------------

    private static Object approvedCallback() throws Exception {
        return Class.forName("com.jeremyliao.liveeventbus.utils.AppUtils$ActivityLifecycleImpl")
            .getDeclaredConstructor().newInstance();
    }

    private static boolean ownedCallback(Object callback) throws Exception {
        java.lang.reflect.Field field =
            GuardedReaderApplication.class.getDeclaredField("ownedCallbacks");
        field.setAccessible(true);
        return ((java.util.List<?>) field.get(null)).contains(callback);
    }

    private static void resourceLifecycleNormal(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks((Application.ActivityLifecycleCallbacks) callback);
        boolean during = io.liber.oracle.nested.BoundaryInspection.callbackOwned;
        boolean ownerExact = io.liber.oracle.nested.BoundaryInspection.storedOwner
            == io.liber.oracle.nested.BoundaryInspection.invokedInstance;
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        result.put("during", during).put("ownerExact", ownerExact)
            .put("registerEffects", app.lifecycleRegisterEffects)
            .put("unregisterEffects", app.lifecycleUnregisterEffects)
            .put("nativeRemaining", app.nativeCallbacks.size()).put("release", release);
        require(during, "the exact callback was reserved during the boundary");
        require(ownerExact, "the boundary ran on the exact armed owner");
        require(app.lifecycleRegisterEffects == 1, "one real native registration effect");
        require(app.lifecycleUnregisterEffects == 1, "one real native removal effect");
        require(app.nativeCallbacks.isEmpty(), "the native registry is empty after release");
        require(release.optBoolean("closed"), "a clean lifecycle closes honestly");
        require(!GuardedReaderApplication.captureFailed(), "a clean path must not fail");
    }

    private static void resourceLifecycleAcquireBefore(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object callback = approvedCallback();
        RuntimeException fault = new IllegalStateException("LIFECYCLE_ACQUIRE_BEFORE",
            new IllegalArgumentException("LIFECYCLE_ACQUIRE_BEFORE_NESTED"));
        fault.addSuppressed(new IllegalStateException("LIFECYCLE_ACQUIRE_BEFORE_SUPPRESSED"));
        app.lifecycleRegisterBeforeEffect = fault;
        boolean refused = refused(() -> app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback));
        result.put("refused", refused)
            .put("during", io.liber.oracle.nested.BoundaryInspection.callbackOwned)
            .put("registerEffects", app.lifecycleRegisterEffects)
            .put("nativeRemaining", app.nativeCallbacks.size())
            .put("owned", ownedCallback(callback));
        require(refused, "a before-effect fault must be rethrown");
        require(io.liber.oracle.nested.BoundaryInspection.callbackOwned,
            "the callback was reserved during the boundary");
        require(app.lifecycleRegisterEffects == 0, "no native effect happened");
        require(app.nativeCallbacks.isEmpty(), "the native registry stays empty");
        require(ownedCallback(callback), "the reserved handle is retained");
        require(GuardedReaderApplication.captureReceipt()
            .optInt("successfulRegistrations") == 0,
            "a before-effect throw must not be acknowledged as successful");
        String failures = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").toString();
        require(failures.contains("LIFECYCLE_ACQUIRE_BEFORE"), "the original cause is retained");
        require(failures.contains("LIFECYCLE_ACQUIRE_BEFORE_NESTED"),
            "the nested cause is retained");
        require(failures.contains("LIFECYCLE_ACQUIRE_BEFORE_SUPPRESSED"),
            "the suppressed error is retained");
        // The real final release acknowledges an absent member as a normal no-op.
        app.lifecycleRegisterBeforeEffect = null;
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        result.put("release", release).put("ownedAfter", ownedCallback(callback));
        require(release.optBoolean("closed"),
            "the real absent no-op acknowledgement closes the owned resource");
        require(!ownedCallback(callback), "the handle is cleared after the acknowledgement");
        require(GuardedReaderApplication.captureFailed(), "the capture failure stays sticky");
    }

    private static void resourceLifecycleAcquireAfter(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object callback = approvedCallback();
        RuntimeException fault = new IllegalStateException("LIFECYCLE_ACQUIRE_AFTER");
        app.lifecycleRegisterAfterEffect = fault;
        boolean refused = refused(() -> app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback));
        result.put("refused", refused)
            .put("registerEffects", app.lifecycleRegisterEffects)
            .put("nativeRemaining", app.nativeCallbacks.size())
            .put("owned", ownedCallback(callback));
        require(refused, "an after-effect fault must be rethrown");
        require(app.lifecycleRegisterEffects == 1, "the native effect really happened");
        require(app.nativeCallbacks.size() == 1, "the native handle is really installed");
        require(ownedCallback(callback), "the reserved handle is not lost");
        require(GuardedReaderApplication.captureReceipt()
            .optInt("successfulRegistrations") == 0,
            "a throwing registration must not be acknowledged as successful");
        app.lifecycleRegisterAfterEffect = null;
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        result.put("release", release).put("nativeAfter", app.nativeCallbacks.size());
        require(app.nativeCallbacks.isEmpty(),
            "the real final release removed the exact callback");
        require(release.optBoolean("closed"), "the resources honestly close after cleanup");
        require(GuardedReaderApplication.captureFailed(), "the capture failure stays sticky");
    }

    private static void resourceLifecycleRemoveBeforeRetry(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks((Application.ActivityLifecycleCallbacks) callback);
        RuntimeException fault = new IllegalStateException("LIFECYCLE_REMOVE_BEFORE");
        app.lifecycleUnregisterBeforeEffect = fault;
        boolean refused = faulted(() -> app.unregisterActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback)) != null;
        result.put("refused", refused).put("nativeRemaining", app.nativeCallbacks.size())
            .put("owned", ownedCallback(callback));
        require(refused, "a before-effect removal fault must be rethrown");
        require(app.nativeCallbacks.size() == 1, "the native handle is still installed");
        require(ownedCallback(callback), "the guard keeps the handle");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
        // The real final release with the fault still set also fails and retains.
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        result.put("release", release).put("nativeAfterFailedRelease", app.nativeCallbacks.size())
            .put("ownedAfterFailedRelease", ownedCallback(callback));
        require(!release.optBoolean("closed"), "the failed final release is not a closure");
        require(app.nativeCallbacks.size() == 1, "the native handle is retained");
        require(ownedCallback(callback), "the owned handle is retained");
        // Clear the fault and retry through the real final release.
        app.lifecycleUnregisterBeforeEffect = null;
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        result.put("retry", retry).put("nativeAfter", app.nativeCallbacks.size())
            .put("unregisterEffects", app.lifecycleUnregisterEffects);
        require(retry.optBoolean("closed"), "the real retry closes the resource");
        require(app.nativeCallbacks.isEmpty(), "the retry really removed the handle");
        require(app.lifecycleUnregisterEffects == 1, "exactly one real removal effect");
        require(!ownedCallback(callback), "ownership is cleared after the acknowledgement");
    }

    private static void resourceLifecycleRemoveAfter(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks((Application.ActivityLifecycleCallbacks) callback);
        RuntimeException fault = new IllegalStateException("LIFECYCLE_REMOVE_AFTER");
        app.lifecycleUnregisterAfterEffect = fault;
        boolean refused = faulted(() -> app.unregisterActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback)) != null;
        result.put("refused", refused).put("nativeRemaining", app.nativeCallbacks.size())
            .put("owned", ownedCallback(callback));
        require(refused, "an after-effect removal fault must be rethrown");
        require(app.nativeCallbacks.isEmpty(), "the native handle really went away");
        require(ownedCallback(callback), "the guard retains uncertain ownership");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
        // Clearing the fault lets the real final absent no-op acknowledge closure.
        app.lifecycleUnregisterAfterEffect = null;
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        result.put("release", release).put("unregisterEffects", app.lifecycleUnregisterEffects)
            .put("ownedAfter", ownedCallback(callback));
        require(release.optBoolean("closed"),
            "the real absent no-op acknowledgement closes the resource");
        require(app.lifecycleUnregisterEffects == 1, "no second native removal effect");
        require(!ownedCallback(callback), "ownership is cleared by the acknowledgement");
    }

    private static void resourceLifecycleEarlyClose(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks((Application.ActivityLifecycleCallbacks) callback);
        app.unregisterActivityLifecycleCallbacks((Application.ActivityLifecycleCallbacks) callback);
        int afterEarly = app.lifecycleUnregisterEffects;
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        result.put("afterEarly", afterEarly)
            .put("afterRelease", app.lifecycleUnregisterEffects).put("release", release);
        require(afterEarly == 1, "the early close removed exactly once");
        require(app.lifecycleUnregisterEffects == 1,
            "the final release must not remove a second time");
        require(app.nativeCallbacks.isEmpty(), "the native registry is empty");
        require(release.optBoolean("closed"), "the resource closes honestly");
    }

    private static void resourceLifecycleForeignOwner(JSONObject result) throws Exception {
        GuardedReaderApplication owner = armedApp();
        Object callback = approvedCallback();
        owner.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        GuardedReaderApplication foreign = new GuardedReaderApplication();
        int ownerBefore = owner.lifecycleUnregisterAttempts;
        int ownerEffectsBefore = owner.lifecycleUnregisterEffects;
        boolean refused = refused(() -> foreign.unregisterActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback));
        result.put("refused", refused)
            .put("foreignAttempts", foreign.lifecycleUnregisterAttempts)
            .put("foreignEffects", foreign.lifecycleUnregisterEffects)
            .put("ownerBefore", ownerBefore).put("ownerAfter", owner.lifecycleUnregisterAttempts)
            .put("ownerNative", owner.nativeCallbacks.size())
            .put("owned", ownedCallback(callback));
        require(refused, "a foreign owner must be refused");
        require(foreign.lifecycleUnregisterAttempts == 0,
            "the foreign instance must not attempt a native removal");
        require(foreign.lifecycleUnregisterEffects == 0,
            "the foreign instance must not effect a native removal");
        require(owner.lifecycleUnregisterAttempts == ownerBefore,
            "the owner's native counters are unchanged by the refusal");
        require(owner.lifecycleUnregisterEffects == ownerEffectsBefore,
            "the owner's native effect count is unchanged by the refusal");
        require(owner.nativeCallbacks.size() == 1,
            "the exact owner handle is still installed after the refusal");
        require(ownedCallback(callback), "the true owner still owns the callback");
        // The correct owner cleans the exact member.
        owner.unregisterActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        result.put("nativeAfter", owner.nativeCallbacks.size())
            .put("unregisterEffects", owner.lifecycleUnregisterEffects);
        require(owner.nativeCallbacks.isEmpty(), "the exact owner removed the callback");
        require(owner.lifecycleUnregisterEffects == 1, "exactly one real removal effect");
    }

    // --- A3 observer and all-domain ownership -----------------------------

    /** Test-only read/write of the overlay's own public fields. */
    private static Object observableField(Object target, String name) throws Exception {
        java.lang.reflect.Field field = target.getClass().getField(name);
        field.setAccessible(true);
        return field.get(target);
    }

    private static void setObservableField(Object target, String name, Object value)
            throws Exception {
        java.lang.reflect.Field field = target.getClass().getField(name);
        field.setAccessible(true);
        field.set(target, value);
    }

    private static Object liveObservableForTest() throws Exception {
        return Class.forName("com.jeremyliao.liveeventbus.LiveEventBus")
            .getMethod("get", String.class, Class.class)
            .invoke(null, GuardedReaderApplication.SAVE_CONTENT_TAG, Class.forName("kotlin.Pair"));
    }

    private static void resourceObserverNormal(JSONObject result) throws Exception {
        arm();
        JSONObject begin =
            GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        boolean tupleExact = io.liber.oracle.nested.BoundaryInspection.observerTupleExact;
        Object observable = liveObservableForTest();
        int installed = (Integer) observableField(observable, "observerObserveEffects");
        deliver("http://book/1", "http://book/1/c1");
        JSONObject end = GuardedReaderApplication.endSaveObservation(2000);
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        int remaining = ((java.util.Map<?, ?>) observableField(observable, "nativeObservers")).size();
        result.put("begin", begin).put("tupleExact", tupleExact).put("installed", installed)
            .put("end", end).put("release", release).put("remaining", remaining);
        require(begin.optBoolean("registered"), "the actual begin acknowledged registration");
        require(tupleExact, "the exact tuple was reserved during the native observe");
        require(installed == 1, "one real native observation effect");
        require(end.optInt("events") == 1, "the typed MAIN event was valid");
        require(remaining == 0, "the native observer registry is empty after release");
        require(release.optBoolean("closed"), "the resources close honestly");
        require(!GuardedReaderApplication.captureFailed(), "a clean path must not fail");
    }

    private static void resourceObserverAcquireBefore(JSONObject result) throws Exception {
        arm();
        Object observable = liveObservableForTest();
        RuntimeException fault = new IllegalStateException("OBSERVER_ACQUIRE_BEFORE",
            new IllegalArgumentException("OBSERVER_ACQUIRE_BEFORE_NESTED"));
        fault.addSuppressed(new IllegalStateException("OBSERVER_ACQUIRE_BEFORE_SUPPRESSED"));
        setObservableField(observable, "observerObserveBeforeEffect", fault);
        Throwable thrown = faulted(() ->
            GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1"));
        boolean tupleExact = io.liber.oracle.nested.BoundaryInspection.observerTupleExact;
        int effects = (Integer) observableField(observable, "observerObserveEffects");
        result.put("thrown", thrown != null).put("tupleExact", tupleExact)
            .put("effects", effects)
            .put("failures", GuardedReaderApplication.captureReceipt()
                .getJSONArray("failures").toString());
        require(thrown != null, "a before-effect fault must be rethrown");
        require(tupleExact, "the complete tuple was reserved before the effect");
        require(effects == 0, "no native observation effect happened");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
        String failures = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").toString();
        require(failures.contains("OBSERVER_ACQUIRE_BEFORE"), "the original cause is retained");
        require(failures.contains("OBSERVER_ACQUIRE_BEFORE_NESTED"), "the nested cause is retained");
        require(failures.contains("OBSERVER_ACQUIRE_BEFORE_SUPPRESSED"),
            "the suppressed error is retained");
        // A second begin must refuse before overwriting the uncertain tuple.
        setObservableField(observable, "observerObserveBeforeEffect", null);
        int observesBefore = (Integer) observableField(observable, "observerObserveAttempts");
        Throwable second = faulted(() ->
            GuardedReaderApplication.beginSaveObservation("http://book/2", "http://book/2/c1"));
        int observesAfter = (Integer) observableField(observable, "observerObserveAttempts");
        result.put("secondRefused", second != null).put("observesBefore", observesBefore)
            .put("observesAfter", observesAfter);
        require(second != null, "a second begin must refuse the uncertain observation");
        require(observesAfter == observesBefore, "the refused begin adds no observe attempt");
        // The real final absent removal is a no-op acknowledgement.
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        result.put("release", release);
        require(release.optBoolean("closed"),
            "the real absent no-op acknowledgement closes the owned resource");
        require(GuardedReaderApplication.captureFailed(),
            "a closed resource never qualifies a failed capture");
    }

    private static void resourceObserverAcquireAfter(JSONObject result) throws Exception {
        arm();
        Object observable = liveObservableForTest();
        RuntimeException fault = new IllegalStateException("OBSERVER_ACQUIRE_AFTER");
        setObservableField(observable, "observerObserveAfterEffect", fault);
        Throwable thrown = faulted(() ->
            GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1"));
        int effects = (Integer) observableField(observable, "observerObserveEffects");
        int installed = ((java.util.Map<?, ?>) observableField(observable, "nativeObservers")).size();
        result.put("thrown", thrown != null).put("effects", effects)
            .put("installed", installed);
        require(thrown != null, "an after-effect fault must be rethrown");
        require(effects == 1, "the native observation really happened before the throw");
        require(installed == 1, "the native observer is really installed");
        setObservableField(observable, "observerObserveAfterEffect", null);
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        int remaining = ((java.util.Map<?, ?>) observableField(observable, "nativeObservers")).size();
        result.put("release", release).put("remaining", remaining);
        require(remaining == 0, "the real final release removed the exact observer");
        require(release.optBoolean("closed"), "the resources honestly close after cleanup");
        require(GuardedReaderApplication.captureFailed(), "the capture failure stays sticky");
    }

    private static void resourceObserverRemoveBeforeRetry(JSONObject result) throws Exception {
        arm();
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        RuntimeException fault = new IllegalStateException("OBSERVER_REMOVE_BEFORE");
        setObservableField(observable, "observerRemoveBeforeEffect", fault);
        Throwable thrown = faulted(() ->
            GuardedReaderApplication.endSaveObservation(2000));
        int remaining = ((java.util.Map<?, ?>) observableField(observable, "nativeObservers")).size();
        result.put("thrown", thrown != null).put("remaining", remaining)
            .put("failures", GuardedReaderApplication.captureReceipt()
                .getJSONArray("failures").toString());
        require(thrown != null, "a before-effect removal fault must be rethrown");
        require(remaining == 1, "the native observer is still installed");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
        // The real final release with the fault still set also fails and retains.
        JSONObject failedRelease = GuardedReaderApplication.releaseProcessResources();
        result.put("failedRelease", failedRelease);
        require(!failedRelease.optBoolean("closed"), "the failed final release is not a closure");
        require(((java.util.Map<?, ?>) observableField(observable, "nativeObservers")).size() == 1,
            "the native observer is retained");
        // Clear the fault and retry through the real final release.
        setObservableField(observable, "observerRemoveBeforeEffect", null);
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        int after = ((java.util.Map<?, ?>) observableField(observable, "nativeObservers")).size();
        result.put("retry", retry).put("after", after);
        require(retry.optBoolean("closed"), "the real retry closes the resource");
        require(after == 0, "the retry really removed the observer");
    }

    private static void resourceObserverRemoveAfter(JSONObject result) throws Exception {
        arm();
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        RuntimeException fault = new IllegalStateException("OBSERVER_REMOVE_AFTER");
        setObservableField(observable, "observerRemoveAfterEffect", fault);
        Throwable thrown = faulted(() ->
            GuardedReaderApplication.endSaveObservation(2000));
        int remaining = ((java.util.Map<?, ?>) observableField(observable, "nativeObservers")).size();
        result.put("thrown", thrown != null).put("remaining", remaining);
        require(thrown != null, "an after-effect removal fault must be rethrown");
        require(remaining == 0, "the native observer really went away");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
        setObservableField(observable, "observerRemoveAfterEffect", null);
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        int effects = (Integer) observableField(observable, "observerRemoveEffects");
        result.put("release", release).put("effects", effects);
        require(release.optBoolean("closed"),
            "the real absent no-op acknowledgement closes the resource");
        require(effects == 1, "no second native removal effect");
    }

    private static void resourceObserverEarlyClose(JSONObject result) throws Exception {
        arm();
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        JSONObject first = GuardedReaderApplication.endSaveObservation(2000);
        JSONObject second = GuardedReaderApplication.endSaveObservation(0);
        int effectsAfterEarly = (Integer) observableField(observable, "observerRemoveEffects");
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        int effectsAfterRelease = (Integer) observableField(observable, "observerRemoveEffects");
        result.put("first", first).put("second", second)
            .put("effectsAfterEarly", effectsAfterEarly)
            .put("effectsAfterRelease", effectsAfterRelease).put("release", release);
        require(first.optInt("events") == 1, "the typed event was valid");
        require(second.optBoolean("alreadyClosed"), "the repeat is an acknowledged close");
        require(effectsAfterEarly == 1, "the early close removed exactly once");
        require(effectsAfterRelease == 1, "the final release adds no native removal");
        require(release.optBoolean("closed"), "the resource closes honestly");
        require(!GuardedReaderApplication.captureFailed(), "a clean path must not fail");
    }

    private static void resourceCleanupErrors(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        // Three actual owned resources: receiver, lifecycle callback, observer.
        app.registerReceiver(newReceiver(), new IntentFilter(ACTION), 2);
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks((Application.ActivityLifecycleCallbacks) callback);
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        RuntimeException observerFault = new IllegalStateException("CLEANUP_OBSERVER",
            new IllegalArgumentException("CLEANUP_OBSERVER_NESTED"));
        observerFault.addSuppressed(new IllegalStateException("CLEANUP_OBSERVER_SUPPRESSED"));
        RuntimeException receiverFault = new IllegalStateException("CLEANUP_RECEIVER");
        RuntimeException lifecycleFault = new IllegalStateException("CLEANUP_LIFECYCLE");
        setObservableField(observable, "observerRemoveBeforeEffect", observerFault);
        app.receiverUnregisterBeforeEffect = receiverFault;
        app.lifecycleUnregisterBeforeEffect = lifecycleFault;
        JSONObject failed = GuardedReaderApplication.releaseProcessResources();
        String failures = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").toString();
        result.put("failed", failed).put("failures", failures)
            .put("observerNative", ((java.util.Map<?, ?>) observableField(observable, "nativeObservers")).size())
            .put("receiverNative", app.nativeReceivers.size())
            .put("lifecycleNative", app.nativeCallbacks.size())
            .put("receiverAttempts", app.receiverUnregisterAttempts)
            .put("lifecycleAttempts", app.lifecycleUnregisterAttempts)
            .put("observerAttempts", (Integer) observableField(observable,
                "observerRemoveAttempts"));
        require(!failed.optBoolean("closed"), "faulted cleanup is not a closure");
        // Every domain was actually attempted despite each failure.
        require(app.receiverUnregisterAttempts == 1, "the receiver domain was attempted");
        require(app.lifecycleUnregisterAttempts == 1, "the lifecycle domain was attempted");
        require((Integer) observableField(observable, "observerRemoveAttempts") == 1, "the observer domain was attempted");
        require(failures.contains("CLEANUP_OBSERVER"), "the observer cause is retained");
        require(failures.contains("CLEANUP_OBSERVER_NESTED"), "the nested cause is retained");
        require(failures.contains("CLEANUP_OBSERVER_SUPPRESSED"),
            "the suppressed error is retained");
        require(failures.contains("CLEANUP_RECEIVER"), "the receiver cause is retained");
        require(failures.contains("CLEANUP_LIFECYCLE"), "the lifecycle cause is retained");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
        // Clear the faults and retry: all three registries empty via real ACK.
        setObservableField(observable, "observerRemoveBeforeEffect", null);
        app.receiverUnregisterBeforeEffect = null;
        app.lifecycleUnregisterBeforeEffect = null;
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        result.put("retry", retry)
            .put("observerAfter", ((java.util.Map<?, ?>) observableField(observable, "nativeObservers")).size())
            .put("receiverAfter", app.nativeReceivers.size())
            .put("lifecycleAfter", app.nativeCallbacks.size());
        require(retry.optBoolean("closed"), "the real retry closes all three resources");
        require(((java.util.Map<?, ?>) observableField(observable, "nativeObservers")).isEmpty(), "the observer is gone");
        require(app.nativeReceivers.isEmpty(), "the receiver is gone");
        require(app.nativeCallbacks.isEmpty(), "the lifecycle callback is gone");
        require(GuardedReaderApplication.captureFailed(), "the capture failure stays sticky");
    }

    // --- A4 registration boundary (filter / route / closing) --------------

    /** A filter subclass whose getters must never run. */
    public static final class TrapFilter extends IntentFilter {
        static int getterCalls;
        TrapFilter() { super(ACTION); }
        @Override public java.util.Iterator<String> actionsIterator() { getterCalls++; return super.actionsIterator(); }
        @Override public int countDataTypes() { getterCalls++; return super.countDataTypes(); }
        @Override public int countDataSchemes() { getterCalls++; return super.countDataSchemes(); }
        @Override public int countCategories() { getterCalls++; return super.countCategories(); }
        @Override public int countDataAuthorities() { getterCalls++; return super.countDataAuthorities(); }
        @Override public int countDataPaths() { getterCalls++; return super.countDataPaths(); }
        @Override public int countDataSchemeSpecificParts() { getterCalls++; return super.countDataSchemeSpecificParts(); }
    }

    private static IntentFilter boundaryFilter(String mode) {
        IntentFilter filter = "boundary-filter-subclass".equals(mode)
            ? new TrapFilter() : new IntentFilter(ACTION);
        if ("boundary-filter-empty".equals(mode)) return new IntentFilter();
        if ("boundary-filter-action".equals(mode)) return new IntentFilter("other.action");
        if ("boundary-filter-extra-action".equals(mode)) {
            filter.addAction("extra.action");
        }
        if ("boundary-filter-type".equals(mode)) filter.addDataType("text/plain");
        if ("boundary-filter-scheme".equals(mode)) filter.addDataScheme("https");
        if ("boundary-filter-category".equals(mode)) filter.addCategory("cat");
        if ("boundary-filter-authority".equals(mode)) filter.addDataAuthority("example.test", null);
        if ("boundary-filter-path".equals(mode)) filter.addDataPath("/private", 0);
        if ("boundary-filter-ssp".equals(mode)) filter.addDataSchemeSpecificPart("private", 0);
        return filter;
    }

    private static void boundaryExactRegistration(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        app.registerReceiver(newReceiver(), new IntentFilter(ACTION), 2);
        Object wrapper = storedWrapper(app, newReceiver());
        result.put("registerEffects", app.receiverRegisterEffects)
            .put("native", app.nativeReceivers.size());
        require(app.receiverRegisterEffects == 1, "the approved plain filter registers once");
        require(app.nativeReceivers.size() == 1, "the native handle is really installed");
        require(!GuardedReaderApplication.captureFailed(), "a valid registration must not fail");
    }

    private static void boundaryFilter(JSONObject result, String mode) throws Exception {
        GuardedReaderApplication app = armedApp();
        TrapFilter.getterCalls = 0;
        boolean refused = refused(() ->
            app.registerReceiver(newReceiver(), boundaryFilter(mode), 2));
        result.put("mode", mode).put("refused", refused)
            .put("getterCalls", TrapFilter.getterCalls)
            .put("nativeAttempts", app.receiverRegisterAttempts)
            .put("nativeEffects", app.receiverRegisterEffects)
            .put("native", app.nativeReceivers.size());
        require(refused, mode + ": the filter must be refused");
        require(app.receiverRegisterEffects == 0, mode + ": no native effect");
        require(app.nativeReceivers.isEmpty(), mode + ": no native handle");
        require(GuardedReaderApplication.captureFailed(), mode + ": the capture must fail");
        require(TrapFilter.getterCalls == 0,
            mode + ": an unapproved filter's getters must never run");
    }

    private static void boundaryRoute(JSONObject result, String mode) throws Exception {
        GuardedReaderApplication app = armedApp();
        TrapFilter.getterCalls = 0;
        boolean refused;
        if ("boundary-flags-zero".equals(mode)) {
            refused = refused(() -> app.registerReceiver(newReceiver(),
                new IntentFilter(ACTION), 0));
        } else if ("boundary-flags-other".equals(mode)) {
            refused = refused(() -> app.registerReceiver(newReceiver(),
                new IntentFilter(ACTION), 4));
        } else if ("boundary-overload2".equals(mode)) {
            refused = refused(() -> app.registerReceiver(newReceiver(),
                new IntentFilter(ACTION)));
        } else if ("boundary-overload4".equals(mode)) {
            refused = refused(() -> app.registerReceiver(newReceiver(),
                new IntentFilter(ACTION), null, null));
        } else if ("boundary-overload5".equals(mode)) {
            refused = refused(() -> app.registerReceiver(newReceiver(),
                new IntentFilter(ACTION), null, null, 2));
        } else if ("boundary-null-receiver".equals(mode)) {
            refused = refused(() -> app.registerReceiver(null, new IntentFilter(ACTION), 2));
        } else {
            refused = refused(() -> app.registerReceiver(newReceiver(), null, 2));
        }
        result.put("mode", mode).put("refused", refused)
            .put("getterCalls", TrapFilter.getterCalls)
            .put("nativeEffects", app.receiverRegisterEffects)
            .put("native", app.nativeReceivers.size());
        require(refused, mode + ": the route must be refused");
        require(app.receiverRegisterEffects == 0, mode + ": no native effect");
        require(app.nativeReceivers.isEmpty(), mode + ": no native handle");
        require(GuardedReaderApplication.captureFailed(), mode + ": the capture must fail");
    }

    private static void boundaryClosed(JSONObject result, String mode) throws Exception {
        GuardedReaderApplication app = armedApp();
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        boolean refused;
        if ("boundary-closed-arm".equals(mode)) {
            refused = refused(() -> GuardedReaderApplication.arm(app, loader()));
        } else if ("boundary-closed-receiver".equals(mode)) {
            refused = refused(() -> app.registerReceiver(newReceiver(),
                new IntentFilter(ACTION), 2));
        } else if ("boundary-closed-lifecycle".equals(mode)) {
            refused = refused(() -> app.registerActivityLifecycleCallbacks(
                (Application.ActivityLifecycleCallbacks) approvedCallback()));
        } else {
            refused = refused(() ->
                GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1"));
        }
        result.put("mode", mode).put("release", release).put("refused", refused)
            .put("receiverEffects", app.receiverRegisterEffects)
            .put("lifecycleEffects", app.lifecycleRegisterEffects)
            .put("nativeReceivers", app.nativeReceivers.size())
            .put("nativeCallbacks", app.nativeCallbacks.size());
        require(release.optBoolean("closed"), mode + ": the lifetime really closed");
        require(refused, mode + ": admission after closing must be refused");
        require(app.receiverRegisterEffects == 0, mode + ": no receiver native effect");
        require(app.lifecycleRegisterEffects == 0, mode + ": no lifecycle native effect");
        require(app.nativeReceivers.isEmpty() && app.nativeCallbacks.isEmpty(),
            mode + ": no native handle after closing");
    }

    /**
     * A controlled thread establishes final closing while the guard is still
     * validating the filter, before its reservation lock. The reservation must
     * recheck closing atomically and refuse with no native effect.
     */
    private static void boundaryCloseBeforeReserve(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        final java.util.concurrent.CountDownLatch reached =
            new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch done =
            new java.util.concurrent.CountDownLatch(1);
        final JSONObject[] release = {null};
        final Throwable[] threadFailure = {null};
        IntentFilter.class.getField("metadataReached").set(null, reached);
        IntentFilter.class.getField("releaseDone").set(null, done);
        Thread closer = new Thread(() -> {
            try {
                reached.await(5, java.util.concurrent.TimeUnit.SECONDS);
                release[0] = GuardedReaderApplication.releaseProcessResources();
            } catch (Throwable error) {
                threadFailure[0] = error;
            } finally {
                done.countDown();
            }
        }, "controlled-final-close");
        closer.start();
        boolean refused;
        try {
            refused = refused(() -> app.registerReceiver(newReceiver(),
                new IntentFilter(ACTION), 2));
        } finally {
            closer.join(5000);
            IntentFilter.class.getField("metadataReached").set(null, null);
            IntentFilter.class.getField("releaseDone").set(null, null);
        }
        result.put("refused", refused).put("release", release[0] == null
                ? JSONObject.NULL : release[0])
            .put("threadFailure", threadFailure[0] == null ? "none"
                : threadFailure[0].toString())
            .put("nativeAttempts", app.receiverRegisterAttempts)
            .put("nativeEffects", app.receiverRegisterEffects)
            .put("native", app.nativeReceivers.size());
        require(threadFailure[0] == null, "the closing thread must not fail");
        require(release[0] != null && release[0].optBoolean("closed"),
            "the controlled thread proved the lifetime closed");
        require(refused, "the reservation must refuse after the atomic close");
        require(app.receiverRegisterEffects == 0,
            "no native registration effect after the atomic close");
        require(app.nativeReceivers.isEmpty(), "no native handle after the atomic close");
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

    /** Runs an action that must fail, and returns the actual throwable. */
    private static Throwable faulted(Refusal action) {
        try {
            action.run();
            return null;
        } catch (Throwable error) {
            return error;
        }
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
