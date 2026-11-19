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
            case "boundary-arm-invalid": boundaryArmInvalid(result); break;
            case "boundary-arm-loader": boundaryArmLoader(result); break;
            case "boundary-arm-same": boundaryArmSame(result); break;
            case "boundary-arm-foreign": boundaryArmForeign(result); break;
            case "boundary-arm-other-loader": boundaryArmOtherLoader(result); break;
            case "boundary-receiver-class": boundaryReceiverClass(result); break;
            case "boundary-lifecycle-class": boundaryLifecycleClass(result); break;
            case "boundary-receiver-loader": boundaryReceiverLoader(result); break;
            case "boundary-lifecycle-loader": boundaryLifecycleLoader(result); break;
            case "boundary-foreign-register": boundaryForeignRegister(result); break;
            case "boundary-duplicate-receiver": boundaryDuplicateReceiver(result); break;
            case "boundary-duplicate-lifecycle": boundaryDuplicateLifecycle(result); break;
            case "boundary-duplicate-receiver-pending": boundaryDuplicateReceiverPending(result); break;
            case "boundary-duplicate-lifecycle-pending": boundaryDuplicateLifecyclePending(result); break;
            case "boundary-unarmed-forwarding": boundaryUnarmedForwarding(result); break;
            case "boundary-activity-refusal": boundaryActivityRefusal(result); break;
            case "boundary-closing-owned-removal": boundaryClosingOwnedRemoval(result); break;
            case "boundary-ipc-open": boundaryIpcOpen(result); break;
            case "boundary-ipc-closing": boundaryIpcClosing(result); break;
            case "a5-cancel-queued-acquire": a5CancelQueuedAcquire(result); break;
            case "a5-direct-main-tracked": a5DirectMainTracked(result); break;
            case "a5-enqueue-refused": a5EnqueueRefused(result); break;
            case "a5-body-error-retained": a5BodyErrorRetained(result); break;
            case "a5-many-cycles-retire": a5ManyCyclesRetire(result); break;
            case "a5-native-inflight-lifecycle": a5NativeInflightLifecycle(result); break;
            case "a5-queued-removal-interrupt": a5QueuedRemovalInterrupt(result); break;
            case "a5-real-timeout-queued": a5RealTimeoutQueued(result); break;
            case "a5-post-throw-before": a5PostThrowBefore(result); break;
            case "a5-post-throw-after-running": a5PostThrowAfterRunning(result); break;
            case "a5-marker-not-drain": a5MarkerNotDrain(result); break;
            case "a5-native-receiver-acquire": a5NativeReceiverAcquire(result); break;
            case "a5-native-observer-acquire": a5NativeObserverAcquire(result); break;
            case "a5-native-receiver-remove-before": a5NativeReceiverRemoveBefore(result); break;
            case "a5-native-receiver-remove-after": a5NativeReceiverRemoveAfter(result); break;
            case "a5-native-lifecycle-remove-before": a5NativeLifecycleRemoveBefore(result); break;
            case "a5-native-lifecycle-remove-after": a5NativeLifecycleRemoveAfter(result); break;
            case "a5-native-observer-remove-before": a5NativeObserverRemoveBefore(result); break;
            case "a5-native-observer-remove-after": a5NativeObserverRemoveAfter(result); break;
            case "a5-native-observer-late-interrupt": a5NativeObserverLateInterrupt(result); break;
            case "a5-native-observer-late-deadline": a5NativeObserverLateDeadline(result); break;
            case "a5-native-observer-late-error": a5NativeObserverLateError(result); break;
            case "a5-native-entry-interrupted-cleanup": a5NativeEntryInterruptedCleanup(result); break;
            case "a5-native-event-wait-interrupt": a5NativeEventWaitInterrupt(result); break;
            case "a5-repair-stale-observation-close": a5RepairStaleObservationClose(result); break;
            case "a5-repair-entry-only-interrupt": a5RepairEntryOnlyInterrupt(result); break;
            case "a5-repair-mid-only-interrupt": a5RepairMidOnlyInterrupt(result); break;
            case "a5-repair-observer-after-effect-late-error":
                a5RepairObserverAfterEffectLateError(result); break;
            case "a5-repair-concurrent-error-retention":
                a5RepairConcurrentErrorRetention(result); break;
            case "a5-repair-receiver-public-error-bookkeeping":
                a5RepairRemovalErrorBookkeeping(result, false, true); break;
            case "a5-repair-receiver-release-error-bookkeeping":
                a5RepairRemovalErrorBookkeeping(result, false, false); break;
            case "a5-repair-lifecycle-public-error-bookkeeping":
                a5RepairRemovalErrorBookkeeping(result, true, true); break;
            case "a5-repair-lifecycle-release-error-bookkeeping":
                a5RepairRemovalErrorBookkeeping(result, true, false); break;
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
        require(inbound.extrasRead == 0, "an inbound IPC attempt must never read the extras");
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

    /** Read-only view of the guard's owned wrapper list. */
    private static java.util.List<?> ownedReceiverList() throws Exception {
        java.lang.reflect.Field field =
            GuardedReaderApplication.class.getDeclaredField("ownedReceivers");
        field.setAccessible(true);
        return (java.util.List<?>) field.get(null);
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

    /**
     * A harmless filter subclass: the real SDK declares the inspected getters
     * final, so this class deliberately overrides none of them.
     */
    public static final class TrapFilter extends IntentFilter {
        TrapFilter() { super(ACTION); }
    }

    private static IntentFilter boundaryFilter(String mode) throws Exception {
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
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        IntentFilter filter = new IntentFilter(ACTION);
        app.registerReceiver(receiver, filter, 2);
        Object wrapper = storedWrapper(app, receiver);
        boolean nativeOwns = wrapper != null && app.nativeReceivers.containsKey(wrapper);
        result.put("registerEffects", app.receiverRegisterEffects)
            .put("metadataReads", filter.metadataReads)
            .put("wrapperStored", wrapper != null)
            .put("nativeOwnsWrapper", nativeOwns)
            .put("native", app.nativeReceivers.size());
        require(app.receiverRegisterEffects == 1, "the approved plain filter registers once");
        require(filter.metadataReads > 0, "a valid plain filter is legitimately validated");
        require(wrapper != null, "the exact wrapper is stored for this receiver");
        require(nativeOwns, "the owner's native registry holds that exact wrapper");
        require(!GuardedReaderApplication.captureFailed(), "a valid registration must not fail");
    }

    private static void boundaryFilter(JSONObject result, String mode) throws Exception {
        GuardedReaderApplication app = armedApp();
        IntentFilter filter = boundaryFilter(mode);
        boolean refused = refused(() -> app.registerReceiver(newReceiver(), filter, 2));
        int filterReads = filter.metadataReads;
        result.put("mode", mode).put("refused", refused)
            .put("metadataReads", filterReads)
            .put("nativeAttempts", app.receiverRegisterAttempts)
            .put("nativeEffects", app.receiverRegisterEffects)
            .put("native", app.nativeReceivers.size());
        require(refused, mode + ": the filter must be refused");
        require(app.receiverRegisterAttempts == 0, mode + ": no native attempt");
        require(app.receiverRegisterEffects == 0, mode + ": no native effect");
        require(app.nativeReceivers.isEmpty(), mode + ": no native handle");
        require(GuardedReaderApplication.captureFailed(), mode + ": the capture must fail");
        if ("boundary-filter-subclass".equals(mode)) {
            require(filterReads == 0,
                mode + ": an unapproved filter's metadata must never be read");
        }
    }

    private static void boundaryRoute(JSONObject result, String mode) throws Exception {
        GuardedReaderApplication app = armedApp();
        // The forbidden 4/5 overloads carry an unapproved filter subclass.
        IntentFilter observed = new TrapFilter();
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
            refused = refused(() -> app.registerReceiver(newReceiver(), observed, null, null));
        } else if ("boundary-overload5".equals(mode)) {
            refused = refused(() -> app.registerReceiver(newReceiver(), observed, null, null, 2));
        } else if ("boundary-null-receiver".equals(mode)) {
            refused = refused(() -> app.registerReceiver(null, new IntentFilter(ACTION), 2));
        } else {
            refused = refused(() -> app.registerReceiver(newReceiver(), null, 2));
        }
        int observedReads = observed.metadataReads;
        result.put("mode", mode).put("refused", refused)
            .put("metadataReads", observedReads)
            .put("nativeAttempts", app.receiverRegisterAttempts)
            .put("nativeEffects", app.receiverRegisterEffects)
            .put("native", app.nativeReceivers.size());
        require(refused, mode + ": the route must be refused");
        require(app.receiverRegisterAttempts == 0, mode + ": no native attempt");
        require(app.receiverRegisterEffects == 0, mode + ": no native effect");
        if ("boundary-overload4".equals(mode) || "boundary-overload5".equals(mode)) {
            require(observedReads == 0,
                mode + ": a forbidden diagnostic must not read unapproved filter metadata");
        }
        require(app.nativeReceivers.isEmpty(), mode + ": no native handle");
        require(GuardedReaderApplication.captureFailed(), mode + ": the capture must fail");
    }

    private static void boundaryClosed(JSONObject result, String mode) throws Exception {
        GuardedReaderApplication app = armedApp();
        // Baseline the actual event observable before the closing refusal.
        Object observable = liveObservableForTest();
        int observeBefore = (Integer) observableField(observable, "observerObserveAttempts");
        int removeBefore = (Integer) observableField(observable, "observerRemoveAttempts");
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
        int observeAfter = (Integer) observableField(observable, "observerObserveAttempts");
        int removeAfter = (Integer) observableField(observable, "observerRemoveAttempts");
        result.put("mode", mode).put("release", release).put("refused", refused)
            .put("receiverAttempts", app.receiverRegisterAttempts)
            .put("receiverEffects", app.receiverRegisterEffects)
            .put("lifecycleAttempts", app.lifecycleRegisterAttempts)
            .put("lifecycleEffects", app.lifecycleRegisterEffects)
            .put("observeAttempts", observeAfter - observeBefore)
            .put("removeAttempts", removeAfter - removeBefore)
            .put("nativeReceivers", app.nativeReceivers.size())
            .put("nativeCallbacks", app.nativeCallbacks.size());
        require(release.optBoolean("closed"), mode + ": the lifetime really closed");
        require(refused, mode + ": admission after closing must be refused");
        require(app.receiverRegisterAttempts == 0, mode + ": no receiver native attempt");
        require(app.receiverRegisterEffects == 0, mode + ": no receiver native effect");
        require(app.lifecycleRegisterAttempts == 0, mode + ": no lifecycle native attempt");
        require(app.lifecycleRegisterEffects == 0, mode + ": no lifecycle native effect");
        require(app.nativeReceivers.isEmpty() && app.nativeCallbacks.isEmpty(),
            mode + ": no native handle after closing");
        if ("boundary-closed-observer".equals(mode)) {
            require(observeAfter == observeBefore,
                mode + ": no observable observe attempt after closing");
            require(removeAfter == removeBefore,
                mode + ": no observable remove attempt after closing");
        }
        require(GuardedReaderApplication.captureFailed(),
            mode + ": the refusal must visibly fail the capture");
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
                : FieldOracleFreeChain.describe(threadFailure[0]))
            .put("closerAlive", closer.isAlive())
            .put("nativeAttempts", app.receiverRegisterAttempts)
            .put("nativeEffects", app.receiverRegisterEffects)
            .put("native", app.nativeReceivers.size());
        require(threadFailure[0] == null, "the closing thread must not fail");
        require(!closer.isAlive(), "the controlled closing thread must have terminated");
        require(app.receiverRegisterAttempts == 0,
            "the atomic close admits no native attempt");
        require(app.receiverRegisterEffects == 0,
            "the atomic close admits no native effect");
        require(release[0] != null && release[0].optBoolean("closed"),
            "the controlled thread proved the lifetime closed");
        require(refused, "the reservation must refuse after the atomic close");
        require(app.receiverRegisterEffects == 0,
            "no native registration effect after the atomic close");
        require(app.nativeReceivers.isEmpty(), "no native handle after the atomic close");
    }

    // --- A4 arm readiness -------------------------------------------------

    /** A loader that records every class it is asked to resolve. */
    public static final class SpyLoader extends ClassLoader {
        final java.util.List<String> queried = new java.util.ArrayList<>();
        SpyLoader(ClassLoader parent) { super(parent); }
        @Override protected Class<?> loadClass(String name, boolean resolve)
                throws ClassNotFoundException {
            queried.add(name);
            return super.loadClass(name, resolve);
        }
    }

    /** A loader that refuses the approved receiver with a rich cause graph. */
    public static final class UnresolvingLoader extends ClassLoader {
        final ClassNotFoundException failure;
        UnresolvingLoader(ClassLoader parent) {
            super(parent);
            failure = new ClassNotFoundException("PARENT_UNRESOLVING_APPROVED_RECEIVER",
                new IllegalStateException("PARENT_LOADER_NESTED_CAUSE"));
            failure.addSuppressed(
                new IllegalArgumentException("PARENT_LOADER_SUPPRESSED_CAUSE"));
        }
        @Override protected Class<?> loadClass(String name, boolean resolve)
                throws ClassNotFoundException {
            if (name.startsWith("com.jeremyliao")) throw failure;
            return super.loadClass(name, resolve);
        }
    }

    private static void boundaryArmInvalid(JSONObject result) throws Exception {
        // (a) genuinely never armed: refusals stay silent and publish nothing.
        boolean nullApp = refused(() -> GuardedReaderApplication.arm(null, loader()));
        boolean wrongType = refused(() ->
            GuardedReaderApplication.arm(new android.app.Application(), loader()));
        boolean nullLoader = refused(() ->
            GuardedReaderApplication.arm(new GuardedReaderApplication(), null));
        int failuresAfterNeverArmed = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").length();
        result.put("nullApp", nullApp).put("wrongType", wrongType)
            .put("nullLoader", nullLoader)
            .put("failuresAfterNeverArmed", failuresAfterNeverArmed)
            .put("armed", GuardedReaderApplication.isArmed());
        require(nullApp, "a null application must be refused");
        require(wrongType, "a foreign application type must be refused");
        require(nullLoader, "a null loader must be refused");
        require(!GuardedReaderApplication.isArmed(), "no armed owner may be published");
        require(failuresAfterNeverArmed == 0,
            "a never-armed refusal must not record a capture failure");
        // (b) an actually armed owner: each invalid argument adds one fresh entry.
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object wrapper = storedWrapper(app, receiver);
        int attempts = app.receiverRegisterAttempts;
        int effects = app.receiverRegisterEffects;
        SpyLoader spy = new SpyLoader(loader());
        org.json.JSONArray activeDeltas = new org.json.JSONArray();
        String[] activeReasons = new String[3];
        for (int i = 0; i < 3; i++) {
            int before = GuardedReaderApplication.captureReceipt()
                .getJSONArray("failures").length();
            boolean refusedOne = i == 0
                ? refused(() -> GuardedReaderApplication.arm(null, spy))
                : i == 1
                    ? refused(() -> GuardedReaderApplication.arm(
                        new android.app.Application(), spy))
                    : refused(() -> GuardedReaderApplication.arm(app, null));
            int after = GuardedReaderApplication.captureReceipt()
                .getJSONArray("failures").length();
            org.json.JSONArray all = GuardedReaderApplication.captureReceipt()
                .getJSONArray("failures");
            activeDeltas.put(after - before);
            activeReasons[i] = after > before ? all.getString(after - 1) : "none";
            require(refusedOne, "each active invalid arm must be refused");
            require(after - before == 1,
                "each active invalid argument must add exactly one failure entry");
        }
        result.put("activeDeltas", activeDeltas)
            .put("activeReasons", new org.json.JSONArray(java.util.Arrays.asList(activeReasons)))
            .put("spyQueries", spy.queried.size())
            .put("sameWrapper", wrapper != null && wrapper == storedWrapper(app, receiver))
            .put("attempts", app.receiverRegisterAttempts)
            .put("effects", app.receiverRegisterEffects)
            .put("native", app.nativeReceivers.size());
        require(activeReasons[0].contains("invalid application argument"),
            "the null-application reason is recorded");
        require(activeReasons[1].contains("invalid application argument"),
            "the foreign-application reason is recorded");
        require(activeReasons[2].contains("null loader argument"),
            "the null-loader reason is recorded");
        require(spy.queried.isEmpty(),
            "an invalid supplied loader must never be consulted");
        require(wrapper != null && wrapper == storedWrapper(app, receiver),
            "the true owner's wrapper is unchanged");
        require(app.receiverRegisterAttempts == attempts,
            "the invalid arms add no native attempt");
        require(app.receiverRegisterEffects == effects,
            "the invalid arms add no native effect");
        require(app.nativeReceivers.size() == 1, "the native handle is unchanged");
        // A normal same-owner admission still works.
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver later = newReceiver();
        app.registerReceiver(later, new IntentFilter(ACTION), 2);
        result.put("ownerStillWorks", storedWrapper(app, later) != null);
        require(storedWrapper(app, later) != null,
            "the same owner still admits a normal registration");
        // (c) after the real closing boundary the same refusals stay visible.
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        require(release.optBoolean("closed"), "the real release closed the resources");
        int attemptsAfterClose = app.receiverRegisterAttempts;
        org.json.JSONArray closedDeltas = new org.json.JSONArray();
        for (int i = 0; i < 3; i++) {
            int before = GuardedReaderApplication.captureReceipt()
                .getJSONArray("failures").length();
            boolean refusedOne = i == 0
                ? refused(() -> GuardedReaderApplication.arm(null, loader()))
                : i == 1
                    ? refused(() -> GuardedReaderApplication.arm(
                        new android.app.Application(), loader()))
                    : refused(() -> GuardedReaderApplication.arm(app, null));
            int after = GuardedReaderApplication.captureReceipt()
                .getJSONArray("failures").length();
            closedDeltas.put(after - before);
            require(refusedOne, "each closed invalid arm must be refused");
            require(after - before == 1,
                "each closed invalid argument must add exactly one failure entry");
        }
        result.put("closedDeltas", closedDeltas)
            .put("attemptsAfterClose", app.receiverRegisterAttempts)
            .put("nativeAfterClose", app.nativeReceivers.size());
        require(app.receiverRegisterAttempts == attemptsAfterClose,
            "the closed invalid arms add no native attempt");
        require(app.nativeReceivers.isEmpty(), "the resources really closed");
        require(GuardedReaderApplication.captureFailed(),
            "the capture failure stays sticky");
    }

    /**
     * The first candidate uses a real unresolving loader, so the actual arm call
     * must refuse without publishing an owner and must keep the whole cause
     * graph. A later compatible loader may still genuinely arm.
     */
    private static void boundaryArmLoader(JSONObject result) throws Exception {
        GuardedReaderApplication app = new GuardedReaderApplication();
        int before = io.liber.oracle.nested.InitLedger.receiverInitializations.get();
        UnresolvingLoader unresolving = new UnresolvingLoader(loader());
        Throwable thrown = faulted(() -> GuardedReaderApplication.arm(app, unresolving));
        int after = io.liber.oracle.nested.InitLedger.receiverInitializations.get();
        JSONObject capture = GuardedReaderApplication.captureReceipt();
        String failures = capture.getJSONArray("failures").toString();
        String chain = thrown == null ? "none" : FieldOracleFreeChain.describe(thrown);
        result.put("thrown", thrown != null).put("armed", GuardedReaderApplication.isArmed())
            .put("receiverInitializations", after - before)
            .put("causeIdentity", thrown != null
                && FieldOracleFreeChain.hasCause(thrown, unresolving.failure))
            .put("failures", failures).put("chain", chain);
        require(thrown != null, "an unresolving first candidate must be refused");
        require(!GuardedReaderApplication.isArmed(),
            "an unresolving first candidate must not publish an owner");
        require(FieldOracleFreeChain.hasCause(thrown, unresolving.failure),
            "the original loader failure must be the cause");
        require(chain.contains("PARENT_UNRESOLVING_APPROVED_RECEIVER")
            && chain.contains("PARENT_LOADER_NESTED_CAUSE")
            && chain.contains("PARENT_LOADER_SUPPRESSED_CAUSE"),
            "the thrown graph keeps the primary, nested and suppressed causes");
        require(failures.contains("PARENT_UNRESOLVING_APPROVED_RECEIVER")
            && failures.contains("PARENT_LOADER_NESTED_CAUSE")
            && failures.contains("PARENT_LOADER_SUPPRESSED_CAUSE"),
            "the capture evidence keeps the whole cause graph");
        require(after == before,
            "readiness must not initialize the approved receiver class");
        require(GuardedReaderApplication.captureFailed(), "the refusal must fail the capture");
        // A compatible loader may still genuinely arm; sticky failure stays.
        int resolvingBefore = io.liber.oracle.nested.InitLedger.receiverInitializations.get();
        GuardedReaderApplication.arm(app, loader());
        int resolvingAfter = io.liber.oracle.nested.InitLedger.receiverInitializations.get();
        result.put("laterArmed", GuardedReaderApplication.isArmed())
            .put("stickyAfterValid", GuardedReaderApplication.captureFailed())
            .put("resolvingInitializations", resolvingAfter - resolvingBefore);
        require(GuardedReaderApplication.isArmed(),
            "a compatible loader may still arm after the refusal");
        require(GuardedReaderApplication.captureFailed(),
            "the earlier capture failure stays sticky");
        require(resolvingAfter == resolvingBefore,
            "a resolving readiness check must not initialize the approved receiver");
    }

    /**
     * The identical open re-arm must preserve every owned identity and counter
     * and must not clear the sticky capture failure.
     */
    private static void boundaryArmSame(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        ClassLoader controlled = loader();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object wrapper = storedWrapper(app, receiver);
        int attempts = app.receiverRegisterAttempts;
        int effects = app.receiverRegisterEffects;
        // A legitimate existing refusal sets sticky failure while staying open.
        boolean refusedOnce = refused(() -> app.registerReceiver(newReceiver(),
            new IntentFilter(ACTION), 0));
        boolean stickyBefore = GuardedReaderApplication.captureFailed();
        GuardedReaderApplication.arm(app, controlled);
        Object afterWrapper = storedWrapper(app, receiver);
        // Constructing another application must not replace the owner.
        android.app.Application other = new GuardedReaderApplication();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver second = newReceiver();
        app.registerReceiver(second, new IntentFilter(ACTION), 2);
        boolean ownerStillWorks = storedWrapper(app, second) != null;
        result.put("refusedOnce", refusedOnce).put("stickyBefore", stickyBefore)
            .put("sameWrapper", wrapper != null && wrapper == afterWrapper)
            .put("attempts", app.receiverRegisterAttempts).put("effects", app.receiverRegisterEffects)
            .put("otherConstructed", other != null).put("ownerStillWorks", ownerStillWorks)
            .put("stickyAfter", GuardedReaderApplication.captureFailed());
        require(refusedOnce && stickyBefore, "the earlier refusal must set sticky failure");
        require(wrapper != null && wrapper == afterWrapper,
            "the identical re-arm preserves the exact wrapper");
        require(app.receiverRegisterAttempts == attempts + 1,
            "only the deliberate second registration adds an attempt");
        require(app.receiverRegisterEffects == effects + 1,
            "only the deliberate second registration adds an effect");
        require(ownerStillWorks,
            "the true owner still admits a registration after another app exists");
        require(GuardedReaderApplication.captureFailed(),
            "the identical re-arm must not clear the sticky failure");
    }

    private static void boundaryArmForeign(JSONObject result) throws Exception {
        GuardedReaderApplication owner = armedApp();
        ClassLoader controlled = loader();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        owner.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object wrapper = storedWrapper(owner, receiver);
        int attempts = owner.receiverRegisterAttempts;
        GuardedReaderApplication foreign = new GuardedReaderApplication();
        SpyLoader spy = new SpyLoader(controlled);
        boolean refused = refused(() -> GuardedReaderApplication.arm(foreign, spy));
        Object afterWrapper = storedWrapper(owner, receiver);
        // The original exact owner and loader still work after the refusal.
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver later = newReceiver();
        owner.registerReceiver(later, new IntentFilter(ACTION), 2);
        result.put("refused", refused).put("spyQueries", spy.queried.size())
            .put("sameWrapper", wrapper != null && wrapper == afterWrapper)
            .put("attemptsBefore", attempts).put("attemptsAfter", owner.receiverRegisterAttempts)
            .put("foreignAttempts", foreign.receiverRegisterAttempts)
            .put("ownerStillWorks", storedWrapper(owner, later) != null)
            .put("armed", GuardedReaderApplication.isArmed());
        require(refused, "a foreign owner must be refused");
        require(spy.queried.isEmpty(),
            "a known foreign owner must never consult the supplied loader");
        require(wrapper != null && wrapper == afterWrapper,
            "the true owner's wrapper is unchanged by the refusal");
        require(owner.receiverRegisterAttempts == attempts + 1,
            "only the deliberate later registration adds an owner attempt");
        require(foreign.receiverRegisterAttempts == 0,
            "the foreign instance makes no native attempt");
        require(storedWrapper(owner, later) != null,
            "the original exact owner and loader still work after the refusal");
        require(GuardedReaderApplication.captureFailed(), "the refusal must fail the capture");
    }

    private static void boundaryArmOtherLoader(JSONObject result) throws Exception {
        GuardedReaderApplication owner = armedApp();
        ClassLoader controlled = loader();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        owner.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object wrapper = storedWrapper(owner, receiver);
        SpyLoader spy = new SpyLoader(controlled);
        boolean refused = refused(() -> GuardedReaderApplication.arm(owner, spy));
        Object afterWrapper = storedWrapper(owner, receiver);
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver later = newReceiver();
        owner.registerReceiver(later, new IntentFilter(ACTION), 2);
        result.put("refused", refused).put("spyQueries", spy.queried.size())
            .put("sameWrapper", wrapper != null && wrapper == afterWrapper)
            .put("ownerStillWorks", storedWrapper(owner, later) != null)
            .put("armed", GuardedReaderApplication.isArmed());
        require(refused, "another loader must be refused");
        require(spy.queried.isEmpty(), "a known other loader must never be consulted");
        require(wrapper != null && wrapper == afterWrapper,
            "the true owner's wrapper is unchanged by the refusal");
        require(storedWrapper(owner, later) != null,
            "the original exact owner and loader still work after the refusal");
        require(GuardedReaderApplication.captureFailed(), "the refusal must fail the capture");
    }

    /** Minimal cause-graph helpers for the driver's own assertions. */
    static final class FieldOracleFreeChain {
        static boolean hasCause(Throwable root, Throwable wanted) {
            if (root == null) return false;
            if (root == wanted) return true;
            if (hasCause(root.getCause(), wanted)) return true;
            for (Throwable suppressed : root.getSuppressed()) {
                if (hasCause(suppressed, wanted)) return true;
            }
            return false;
        }

        static String describe(Throwable root) {
            java.io.StringWriter text = new java.io.StringWriter();
            java.io.PrintWriter writer = new java.io.PrintWriter(text);
            root.printStackTrace(writer);
            writer.flush();
            return text.toString();
        }
    }

    // --- A4 identity and duplicate admission ------------------------------

    /** A receiver of an unapproved class. */
    public static final class WrongReceiver extends BroadcastReceiver {
        @Override public void onReceive(Context context, Intent intent) {}
    }

    /** A lifecycle callback of an unapproved class. */
    public static final class WrongLifecycle
            implements Application.ActivityLifecycleCallbacks {
        @Override public void onActivityCreated(android.app.Activity a, android.os.Bundle s) {}
        @Override public void onActivityStarted(android.app.Activity a) {}
        @Override public void onActivityResumed(android.app.Activity a) {}
        @Override public void onActivityPaused(android.app.Activity a) {}
        @Override public void onActivityStopped(android.app.Activity a) {}
        @Override public void onActivitySaveInstanceState(android.app.Activity a,
                android.os.Bundle s) {}
        @Override public void onActivityDestroyed(android.app.Activity a) {}
    }

    /** Child-first for exactly one name, so the same FQCN becomes a new Class. */
    public static final class SameNameLoader extends java.net.URLClassLoader {
        final String name;
        SameNameLoader(java.net.URL[] urls, ClassLoader parent, String name) {
            super(urls, parent);
            this.name = name;
        }
        @Override protected Class<?> loadClass(String target, boolean resolve)
                throws ClassNotFoundException {
            if (!name.equals(target)) return super.loadClass(target, resolve);
            Class<?> found = findLoadedClass(target);
            if (found == null) found = findClass(target);
            if (resolve) resolveClass(found);
            return found;
        }
    }

    private static void boundaryReceiverClass(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        boolean refused = refused(() ->
            app.registerReceiver(new WrongReceiver(), new IntentFilter(ACTION), 2));
        boolean sticky = GuardedReaderApplication.captureFailed();
        int effects = app.receiverRegisterEffects;
        int attempts = app.receiverRegisterAttempts;
        // A real valid control still works after the refusal.
        app.registerReceiver(newReceiver(), new IntentFilter(ACTION), 2);
        result.put("refused", refused).put("sticky", sticky).put("effects", effects)
            .put("attempts", attempts)
            .put("validAfter", app.receiverRegisterEffects)
            .put("native", app.nativeReceivers.size());
        require(refused, "a wrong receiver class must be refused");
        require(attempts == 0, "no native attempt for the wrong class");
        require(effects == 0, "no native effect for the wrong class");
        require(sticky, "the refusal must fail the capture");
        require(app.receiverRegisterEffects == 1,
            "a valid control still registers after the refusal");
    }

    private static void boundaryLifecycleClass(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        boolean refused = refused(() -> app.registerActivityLifecycleCallbacks(
            new WrongLifecycle()));
        boolean sticky = GuardedReaderApplication.captureFailed();
        int effects = app.lifecycleRegisterEffects;
        int attempts = app.lifecycleRegisterAttempts;
        app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) approvedCallback());
        result.put("refused", refused).put("sticky", sticky).put("effects", effects)
            .put("attempts", attempts)
            .put("validAfter", app.lifecycleRegisterEffects);
        require(refused, "a wrong lifecycle class must be refused");
        require(attempts == 0, "no native attempt for the wrong class");
        require(effects == 0, "no native effect for the wrong class");
        require(sticky, "the refusal must fail the capture");
        require(app.lifecycleRegisterEffects == 1,
            "a valid control still registers after the refusal");
    }

    private static Object sameNameInstance(String className) throws Exception {
        java.io.File overlay = new java.io.File(
            Class.forName("com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver")
                .getProtectionDomain().getCodeSource().getLocation().toURI());
        SameNameLoader loader = new SameNameLoader(
            new java.net.URL[] {overlay.toURI().toURL()},
            GuardedReaderApplicationTest.class.getClassLoader(), className);
        Class<?> foreign = Class.forName(className, true, loader);
        return foreign.getDeclaredConstructor().newInstance();
    }

    private static void boundaryReceiverLoader(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object foreign = sameNameInstance(
            "com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver");
        Class<?> approved = newReceiver().getClass();
        boolean sameName = foreign.getClass().getName().equals(approved.getName());
        boolean differentClass = foreign.getClass() != approved;
        boolean refused = refused(() -> app.registerReceiver(
            (android.content.BroadcastReceiver) foreign, new IntentFilter(ACTION), 2));
        result.put("sameName", sameName).put("differentClass", differentClass)
            .put("refused", refused).put("effects", app.receiverRegisterEffects)
            .put("attempts", app.receiverRegisterAttempts)
            .put("native", app.nativeReceivers.size());
        require(sameName, "the foreign object must carry the approved FQCN");
        require(differentClass, "the foreign object must be a different Class");
        require(refused, "a same-name wrong-loader receiver must be refused");
        require(app.receiverRegisterAttempts == 0, "no native attempt");
        require(app.receiverRegisterEffects == 0, "no native effect");
        require(app.nativeReceivers.isEmpty(), "no native handle");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
    }

    private static void boundaryLifecycleLoader(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object foreign = sameNameInstance(
            "com.jeremyliao.liveeventbus.utils.AppUtils$ActivityLifecycleImpl");
        Class<?> approved = approvedCallback().getClass();
        boolean sameName = foreign.getClass().getName().equals(approved.getName());
        boolean differentClass = foreign.getClass() != approved;
        boolean refused = refused(() -> app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) foreign));
        result.put("sameName", sameName).put("differentClass", differentClass)
            .put("refused", refused).put("effects", app.lifecycleRegisterEffects)
            .put("attempts", app.lifecycleRegisterAttempts)
            .put("native", app.nativeCallbacks.size());
        require(sameName, "the foreign object must carry the approved FQCN");
        require(differentClass, "the foreign object must be a different Class");
        require(refused, "a same-name wrong-loader lifecycle must be refused");
        require(app.lifecycleRegisterAttempts == 0, "no native attempt");
        require(app.lifecycleRegisterEffects == 0, "no native effect");
        require(app.nativeCallbacks.isEmpty(), "no native handle");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
    }

    private static void boundaryForeignRegister(JSONObject result) throws Exception {
        GuardedReaderApplication owner = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        owner.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object wrapper = storedWrapper(owner, receiver);
        int ownerAttempts = owner.receiverRegisterAttempts;
        GuardedReaderApplication foreign = new GuardedReaderApplication();
        int failuresBefore = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").length();
        boolean receiverRefused = refused(() -> foreign.registerReceiver(
            newReceiver(), new IntentFilter(ACTION), 2));
        int failuresAfterReceiver = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").length();
        boolean lifecycleRefused = refused(() -> foreign.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) approvedCallback()));
        int failuresAfterLifecycle = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").length();
        String failures = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").toString();
        // The original owner still admits and keeps its identities.
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver later = newReceiver();
        owner.registerReceiver(later, new IntentFilter(ACTION), 2);
        result.put("receiverRefused", receiverRefused)
            .put("lifecycleRefused", lifecycleRefused)
            .put("failuresBefore", failuresBefore)
            .put("failuresAfterReceiver", failuresAfterReceiver)
            .put("failuresAfterLifecycle", failuresAfterLifecycle)
            .put("failures", failures)
            .put("foreignReceiverAttempts", foreign.receiverRegisterAttempts)
            .put("foreignLifecycleAttempts", foreign.lifecycleRegisterAttempts)
            .put("sameWrapper", wrapper != null && wrapper == storedWrapper(owner, receiver))
            .put("ownerAttempts", owner.receiverRegisterAttempts)
            .put("ownerStillWorks", storedWrapper(owner, later) != null);
        require(receiverRefused, "the foreign receiver route must be refused");
        require(lifecycleRefused, "the foreign lifecycle route must be refused");
        require(failuresAfterReceiver == failuresBefore + 1,
            "the receiver route records exactly one new failure");
        require(failuresAfterLifecycle == failuresAfterReceiver + 1,
            "the lifecycle route records exactly one new failure");
        require(failures.contains("receiver registration by a foreign owner instance"),
            "the receiver refusal reason is recorded");
        require(failures.contains("lifecycle registration by a foreign owner instance"),
            "the lifecycle refusal reason is recorded");
        require(foreign.receiverRegisterAttempts == 0
            && foreign.lifecycleRegisterAttempts == 0,
            "the foreign instance makes no native attempt");
        require(wrapper != null && wrapper == storedWrapper(owner, receiver),
            "the true owner's wrapper is unchanged");
        require(owner.receiverRegisterAttempts == ownerAttempts + 1,
            "only the deliberate later owner registration adds an attempt");
        require(storedWrapper(owner, later) != null,
            "the original owner still admits after the refusals");
        require(GuardedReaderApplication.captureFailed(), "both refusals fail the capture");
    }

    private static void boundaryDuplicateReceiver(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object wrapper = storedWrapper(app, receiver);
        int effects = app.receiverRegisterEffects;
        int acks = GuardedReaderApplication.captureReceipt()
            .optInt("successfulRegistrations");
        boolean refused = refused(() ->
            app.registerReceiver(receiver, new IntentFilter(ACTION), 2));
        int attemptsAfter = app.receiverRegisterAttempts;
        int acksAfter = GuardedReaderApplication.captureReceipt()
            .optInt("successfulRegistrations");
        // Snapshot the exact first identity BEFORE any cleanup.
        boolean sameWrapperBefore = wrapper != null && wrapper == storedWrapper(app, receiver);
        boolean nativeHeld = wrapper != null && app.nativeReceivers.containsKey(wrapper);
        boolean ownedHeld = wrapper != null && ownedReceiverList().contains(wrapper);
        // A legitimate exact-owner cleanup empties both registries.
        app.unregisterReceiver(receiver);
        result.put("refused", refused).put("effects", effects)
            .put("effectsAfter", app.receiverRegisterEffects)
            .put("attemptsAfter", attemptsAfter)
            .put("acks", acks).put("acksAfter", acksAfter)
            .put("sameWrapperBefore", sameWrapperBefore)
            .put("nativeHeld", nativeHeld).put("ownedHeld", ownedHeld)
            .put("nativeAfterCleanup", app.nativeReceivers.size())
            .put("ownedAfterCleanup", ownedReceiverList().size())
            .put("wrapperAfterCleanup", storedWrapper(app, receiver));
        require(refused, "a duplicate receiver must be refused");
        require(attemptsAfter == 1, "the duplicate adds no native attempt");
        require(app.receiverRegisterEffects == effects, "no second native effect");
        require(acksAfter == 1, "the acknowledgement stays one after the refusal");
        require(sameWrapperBefore, "the first exact wrapper was retained before cleanup");
        require(nativeHeld, "the exact wrapper is in the native registry before cleanup");
        require(ownedHeld, "the exact wrapper is guard-owned before cleanup");
        require(app.nativeReceivers.isEmpty(), "cleanup empties the native registry");
        require(ownedReceiverList().isEmpty(), "cleanup empties the owned list");
        require(storedWrapper(app, receiver) == null, "cleanup clears the owned wrapper");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
    }

    private static void boundaryDuplicateLifecycle(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        int effects = app.lifecycleRegisterEffects;
        int acks = GuardedReaderApplication.captureReceipt()
            .optInt("successfulRegistrations");
        boolean refused = refused(() -> app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback));
        int attemptsAfter = app.lifecycleRegisterAttempts;
        int acksAfter = GuardedReaderApplication.captureReceipt()
            .optInt("successfulRegistrations");
        boolean nativeHeld = app.nativeCallbacks.containsKey(callback);
        boolean ownedHeld = ownedCallback(callback);
        app.unregisterActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        result.put("refused", refused).put("effects", effects)
            .put("effectsAfter", app.lifecycleRegisterEffects)
            .put("attemptsAfter", attemptsAfter)
            .put("acks", acks).put("acksAfter", acksAfter)
            .put("nativeHeld", nativeHeld).put("ownedHeld", ownedHeld)
            .put("nativeAfterCleanup", app.nativeCallbacks.size())
            .put("ownedAfterCleanup", ownedCallback(callback));
        require(refused, "a duplicate lifecycle must be refused");
        require(attemptsAfter == 1, "the duplicate adds no native attempt");
        require(app.lifecycleRegisterEffects == effects, "no second native effect");
        require(acksAfter == 1, "the acknowledgement stays one after the refusal");
        require(nativeHeld, "the exact callback is native before cleanup");
        require(ownedHeld, "the exact callback is guard-owned before cleanup");
        require(app.nativeCallbacks.isEmpty(), "cleanup empties the native registry");
        require(!ownedCallback(callback), "cleanup clears the owned callback");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
    }

    private static void boundaryDuplicateReceiverPending(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        final java.util.concurrent.CountDownLatch entered =
            new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch release =
            new java.util.concurrent.CountDownLatch(1);
        Application.class.getField("registerEntered").set(null, entered);
        Application.class.getField("registerHeld").set(null, release);
        final com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        final Throwable[] firstError = {null};
        Thread first = new Thread(() -> {
            try {
                app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
            } catch (Throwable error) {
                firstError[0] = error;
            }
        }, "controlled-first-register");
        first.start();
        boolean enteredOk;
        try {
            enteredOk = entered.await(5, java.util.concurrent.TimeUnit.SECONDS);
            // The first native boundary must be genuinely entered first.
            require(enteredOk, "the first native boundary must be entered");
            boolean refused = refused(() ->
                app.registerReceiver(receiver, new IntentFilter(ACTION), 2));
            result.put("entered", enteredOk).put("refused", refused)
                .put("attemptsWhileHeld", app.receiverRegisterAttempts)
                .put("effectsWhileHeld", app.receiverRegisterEffects);
            require(enteredOk, "the first native boundary must be entered");
            require(refused, "the pending duplicate must be refused");
            require(app.receiverRegisterEffects == 0,
                "the duplicate must not add a native effect while the first is held");
        } finally {
            release.countDown();
            Application.class.getField("registerEntered").set(null, null);
            Application.class.getField("registerHeld").set(null, null);
            first.join(5000);
        }
        result.put("firstError", firstError[0] == null ? "none"
                : FieldOracleFreeChain.describe(firstError[0]))
            .put("firstAlive", first.isAlive())
            .put("attempts", app.receiverRegisterAttempts)
            .put("effects", app.receiverRegisterEffects)
            .put("native", app.nativeReceivers.size())
            .put("acks", GuardedReaderApplication.captureReceipt()
                .optInt("successfulRegistrations"));
        require(firstError[0] == null, "the first registration must complete normally");
        require(!first.isAlive(), "the first registration thread must have terminated");
        require(app.receiverRegisterAttempts == 1,
            "only the held first call reaches the native boundary");
        require(app.receiverRegisterEffects == 1, "exactly one native effect");
        require(app.nativeReceivers.size() == 1, "exactly one native handle");
        require(GuardedReaderApplication.captureReceipt()
            .optInt("successfulRegistrations") == 1, "one acknowledged registration");
        app.unregisterReceiver(receiver);
        result.put("nativeAfterCleanup", app.nativeReceivers.size())
            .put("ownedAfterCleanup", ownedReceiverList().size());
        require(app.nativeReceivers.isEmpty(), "cleanup empties the native registry");
        require(ownedReceiverList().isEmpty(), "cleanup empties the owned list");
        require(GuardedReaderApplication.captureFailed(), "the refusal stays sticky");
    }

    private static void boundaryDuplicateLifecyclePending(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        final java.util.concurrent.CountDownLatch entered =
            new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch release =
            new java.util.concurrent.CountDownLatch(1);
        Application.class.getField("lifecycleEntered").set(null, entered);
        Application.class.getField("lifecycleHeld").set(null, release);
        final Object callback = approvedCallback();
        final Throwable[] firstError = {null};
        Thread first = new Thread(() -> {
            try {
                app.registerActivityLifecycleCallbacks(
                    (Application.ActivityLifecycleCallbacks) callback);
            } catch (Throwable error) {
                firstError[0] = error;
            }
        }, "controlled-first-lifecycle");
        first.start();
        boolean enteredOk;
        try {
            enteredOk = entered.await(5, java.util.concurrent.TimeUnit.SECONDS);
            require(enteredOk, "the first native boundary must be entered");
            boolean refused = refused(() -> app.registerActivityLifecycleCallbacks(
                (Application.ActivityLifecycleCallbacks) callback));
            result.put("entered", enteredOk).put("refused", refused)
                .put("attemptsWhileHeld", app.lifecycleRegisterAttempts)
                .put("effectsWhileHeld", app.lifecycleRegisterEffects);
            require(enteredOk, "the first native boundary must be entered");
            require(refused, "the pending lifecycle duplicate must be refused");
            require(app.lifecycleRegisterEffects == 0,
                "the duplicate must not add a native effect while the first is held");
        } finally {
            release.countDown();
            Application.class.getField("lifecycleEntered").set(null, null);
            Application.class.getField("lifecycleHeld").set(null, null);
            first.join(5000);
        }
        result.put("firstError", firstError[0] == null ? "none"
                : FieldOracleFreeChain.describe(firstError[0]))
            .put("firstAlive", first.isAlive())
            .put("attempts", app.lifecycleRegisterAttempts)
            .put("effects", app.lifecycleRegisterEffects)
            .put("native", app.nativeCallbacks.size())
            .put("acks", GuardedReaderApplication.captureReceipt()
                .optInt("successfulRegistrations"));
        require(firstError[0] == null, "the first lifecycle registration must complete");
        require(!first.isAlive(), "the first lifecycle thread must have terminated");
        require(app.lifecycleRegisterAttempts == 1,
            "only the held first call reaches the native boundary");
        require(app.lifecycleRegisterEffects == 1, "exactly one native effect");
        require(app.nativeCallbacks.size() == 1, "exactly one native callback");
        require(GuardedReaderApplication.captureReceipt()
            .optInt("successfulRegistrations") == 1, "one acknowledged registration");
        app.unregisterActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        result.put("nativeAfterCleanup", app.nativeCallbacks.size())
            .put("ownedAfterCleanup", ownedCallback(callback));
        require(app.nativeCallbacks.isEmpty(), "cleanup empties the native registry");
        require(!ownedCallback(callback), "cleanup clears the owned callback");
        require(GuardedReaderApplication.captureFailed(), "the refusal stays sticky");
    }

    // --- A4 inactive forwarding and always-on activity refusal ------------

    /**
     * While genuinely unarmed, every public overload reaches its own native route
     * with the exact supplied objects, and lifecycle registration forwards too.
     */
    /**
     * One actual native observation captured immediately after a public call.
     */
    private static void requireRoute(GuardedReaderApplication app, String route,
            Object receiver, Object filter, int flags, String permission,
            android.os.Handler scheduler, Object sticky, Object back,
            int attempts, int effects, String label) {
        require(app.receiverRoutes.size() == attempts,
            label + ": exactly one native route per call");
        require(app.receiverRoutes.get(attempts - 1).startsWith(route + ":"),
            label + ": the call reached its own native route");
        require(app.lastReceiver == receiver, label + ": the exact receiver reached native");
        require(app.lastFilter == filter, label + ": the exact filter reached native");
        require(app.receiverNativeFlags == flags, label + ": the supplied flags reached native");
        require(app.receiverNativePermission == permission,
            label + ": the exact permission object reached native");
        require(app.receiverNativeScheduler == scheduler,
            label + ": the exact scheduler object reached native");
        require(back == sticky, label + ": the exact sticky intent was returned");
        require(app.receiverRegisterAttempts == attempts, label + ": one native attempt");
        require(app.receiverRegisterEffects == effects, label + ": one native effect");
        require(app.nativeReceivers.containsKey(receiver),
            label + ": the original receiver is in the native registry");
    }

    private static void boundaryUnarmedForwarding(JSONObject result) throws Exception {
        GuardedReaderApplication app = new GuardedReaderApplication();
        require(!GuardedReaderApplication.isArmed(), "the guard must be genuinely unarmed");
        IntentFilter filter2 = new IntentFilter(ACTION);
        IntentFilter filter3 = new IntentFilter(ACTION);
        IntentFilter filter4 = new IntentFilter(ACTION);
        IntentFilter filter5 = new IntentFilter(ACTION);
        android.os.Handler s4 = new android.os.Handler(android.os.Looper.getMainLooper());
        android.os.Handler s5 = new android.os.Handler(android.os.Looper.getMainLooper());
        String permission4 = new String("perm-4");
        String permission5 = new String("perm-5");
        Intent sticky2 = new Intent("sticky.2");
        Intent sticky3 = new Intent("sticky.3");
        Intent sticky4 = new Intent("sticky.4");
        Intent sticky5 = new Intent("sticky.5");
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver r2 = newReceiver();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver r3 = newReceiver();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver r4 = newReceiver();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver r5 = newReceiver();
        app.receiverNativeReturn = sticky2;
        Intent back2 = app.registerReceiver(r2, filter2);
        requireRoute(app, "2", r2, filter2, 0, null, null, sticky2, back2, 1, 1, "route2");
        app.receiverNativeReturn = sticky3;
        Intent back3 = app.registerReceiver(r3, filter3, 2);
        requireRoute(app, "3", r3, filter3, 2, null, null, sticky3, back3, 2, 2, "route3");
        app.receiverNativeReturn = sticky4;
        Intent back4 = app.registerReceiver(r4, filter4, permission4, s4);
        requireRoute(app, "4", r4, filter4, 0, permission4, s4, sticky4, back4, 3, 3, "route4");
        app.receiverNativeReturn = sticky5;
        Intent back5 = app.registerReceiver(r5, filter5, permission5, s5, 4);
        requireRoute(app, "5", r5, filter5, 4, permission5, s5, sticky5, back5, 4, 4, "route5");
        result.put("routes", new org.json.JSONArray(app.receiverRoutes))
            .put("attempts", app.receiverRegisterAttempts)
            .put("effects", app.receiverRegisterEffects)
            .put("armed", GuardedReaderApplication.isArmed());
        require(!GuardedReaderApplication.isArmed(), "forwarding must not arm the guard");
        require(!GuardedReaderApplication.captureFailed(),
            "unarmed forwarding must not fail a capture");
        require(GuardedReaderApplication.captureReceipt()
            .optInt("successfulRegistrations") == 0,
            "unarmed forwarding must not invent a guard acknowledgement");
        // Lifecycle registration and removal forward with the exact callback.
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        boolean registered = app.nativeCallbacks.containsKey(callback);
        app.unregisterActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        result.put("lifecycleRegistered", registered)
            .put("lifecycleRemoved", !app.nativeCallbacks.containsKey(callback))
            .put("lifecycleEffects", app.lifecycleRegisterEffects)
            .put("lifecycleRemovals", app.lifecycleUnregisterEffects);
        require(registered, "the exact callback reaches the native registry");
        require(!app.nativeCallbacks.containsKey(callback),
            "the exact callback is removed natively");
        require(app.lifecycleRegisterEffects == 1 && app.lifecycleUnregisterEffects == 1,
            "one native lifecycle effect each way");
        require(!GuardedReaderApplication.captureFailed(),
            "unarmed lifecycle forwarding must not fail a capture");
        // Remove the four actual native handles, leaving nothing live.
        app.unregisterReceiver(r2);
        app.unregisterReceiver(r3);
        app.unregisterReceiver(r4);
        app.unregisterReceiver(r5);
        result.put("nativeAfter", app.nativeReceivers.size());
        require(app.nativeReceivers.isEmpty(), "no test-owned native handle stays live");
        app.receiverNativeReturn = null;
    }

    /**
     * Both always-on activity overloads refuse before any native effect, first
     * unarmed and then armed on the same real owner.
     */
    private static void boundaryActivityRefusal(JSONObject result) throws Exception {
        GuardedReaderApplication app = new GuardedReaderApplication();
        require(!GuardedReaderApplication.isArmed(), "the guard must start unarmed");
        int base = GuardedReaderApplication.launchAttempts();
        boolean unarmedOne = refused(() -> app.startActivity(new Intent("x")));
        int afterUnarmedOne = GuardedReaderApplication.launchAttempts();
        boolean unarmedTwo = refused(() ->
            app.startActivity(new Intent("x"), new android.os.Bundle()));
        int afterUnarmedTwo = GuardedReaderApplication.launchAttempts();
        GuardedReaderApplication.arm(app, loader());
        boolean armedOne = refused(() -> app.startActivity(new Intent("x")));
        int afterArmedOne = GuardedReaderApplication.launchAttempts();
        boolean armedTwo = refused(() ->
            app.startActivity(new Intent("x"), new android.os.Bundle()));
        int afterArmedTwo = GuardedReaderApplication.launchAttempts();
        result.put("unarmedOne", unarmedOne).put("unarmedTwo", unarmedTwo)
            .put("armedOne", armedOne).put("armedTwo", armedTwo)
            .put("deltas", new org.json.JSONArray().put(afterUnarmedOne - base)
                .put(afterUnarmedTwo - afterUnarmedOne)
                .put(afterArmedOne - afterUnarmedTwo)
                .put(afterArmedTwo - afterArmedOne))
            .put("baseLaunches", app.launched.size());
        require(unarmedOne && unarmedTwo && armedOne && armedTwo,
            "all four activity calls must refuse");
        require(afterUnarmedOne - base == 1 && afterUnarmedTwo - afterUnarmedOne == 1
            && afterArmedOne - afterUnarmedTwo == 1 && afterArmedTwo - afterArmedOne == 1,
            "each call increments the existing activity counter exactly once");
        require(app.launched.isEmpty(),
            "the native base launch must never be reached");
    }

    // --- A4 closing-owned removal and IPC delivery ------------------------

    /** The guard's own receipt counters for the IPC rows. */
    private static int blockedDeliveries() throws Exception {
        java.lang.reflect.Field field =
            GuardedReaderApplication.class.getDeclaredField("blockedDeliveries");
        field.setAccessible(true);
        return ((java.util.concurrent.atomic.AtomicInteger) field.get(null)).get();
    }

    private static int inboundAttempts() throws Exception {
        java.lang.reflect.Field field =
            GuardedReaderApplication.class.getDeclaredField("inboundAttempts");
        field.setAccessible(true);
        return ((org.json.JSONArray) field.get(null)).length();
    }

    private static org.json.JSONArray inboundRecords() throws Exception {
        java.lang.reflect.Field field =
            GuardedReaderApplication.class.getDeclaredField("inboundAttempts");
        field.setAccessible(true);
        return (org.json.JSONArray) field.get(null);
    }

    private static int failureCount() throws Exception {
        return GuardedReaderApplication.captureReceipt().getJSONArray("failures").length();
    }

    /**
     * After a real closing boundary, the exact owner can still remove its own
     * resources, and a final retry empties both registries.
     */
    private static void boundaryClosingOwnedRemoval(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object wrapper = storedWrapper(app, receiver);
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        // Real before-removal faults on all three resources.
        app.receiverUnregisterBeforeEffect = new IllegalStateException("CLOSING_RECEIVER");
        app.lifecycleUnregisterBeforeEffect = new IllegalStateException("CLOSING_LIFECYCLE");
        observableField(observable, "observerRemoveBeforeEffect");
        setObservableField(observable, "observerRemoveBeforeEffect",
            new IllegalStateException("CLOSING_OBSERVER"));
        JSONObject first = GuardedReaderApplication.releaseProcessResources();
        result.put("firstClosed", first.optBoolean("closed"))
            .put("nativeReceiversHeld", app.nativeReceivers.size())
            .put("nativeCallbacksHeld", app.nativeCallbacks.size())
            .put("ownedWrapperHeld", wrapper != null && storedWrapper(app, receiver) != null);
        require(!first.optBoolean("closed"), "the faulted first release is not a closure");
        require(app.nativeReceivers.size() == 1, "the receiver resource is retained");
        require(app.nativeCallbacks.size() == 1, "the lifecycle resource is retained");
        require(wrapper != null && storedWrapper(app, receiver) != null,
            "the owned wrapper is retained");
        require(GuardedReaderApplication.captureFailed(), "the capture must fail");
        // Clear only the controlled native faults.
        app.receiverUnregisterBeforeEffect = null;
        app.lifecycleUnregisterBeforeEffect = null;
        setObservableField(observable, "observerRemoveBeforeEffect", null);
        // Legitimate exact-owner public removal still works after closing.
        app.unregisterReceiver(receiver);
        app.unregisterActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        GuardedReaderApplication.endSaveObservation(0);
        result.put("receiverAfterPublic", app.nativeReceivers.size())
            .put("lifecycleAfterPublic", app.nativeCallbacks.size());
        require(app.nativeReceivers.isEmpty(), "the exact-owner receiver removal works");
        require(app.nativeCallbacks.isEmpty(), "the exact-owner lifecycle removal works");
        // A final acknowledged retry empties everything.
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        result.put("retryClosed", retry.optBoolean("closed"))
            .put("nativeReceivers", app.nativeReceivers.size())
            .put("nativeCallbacks", app.nativeCallbacks.size())
            .put("ownedWrappers", ownedReceiverList().size())
            .put("sticky", GuardedReaderApplication.captureFailed());
        require(retry.optBoolean("closed"), "the final retry closes the resources");
        require(app.nativeReceivers.isEmpty() && app.nativeCallbacks.isEmpty(),
            "the final retry empties the native registries");
        require(ownedReceiverList().isEmpty(), "the final retry empties the owned list");
        require(GuardedReaderApplication.captureFailed(),
            "the capture failure stays sticky after truthful closure");
    }

    /** Invokes the exact native-installed wrapper and checks the guarded facts. */
    private static void ipcDelivery(JSONObject result, String mode) throws Exception {
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object wrapper = storedWrapper(app, receiver);
        require(wrapper != null, "the guard installed a wrapper");
        require(wrapper != receiver, "the installed wrapper is distinct from the original");
        require(app.nativeReceivers.containsKey(wrapper),
            "the exact wrapper is the native-installed object");
        if ("boundary-ipc-closing".equals(mode)) {
            JSONObject release = GuardedReaderApplication.releaseProcessResources();
            result.put("release", release);
            require(release.optBoolean("closed"), "the real release closed the resources");
            require(app.nativeReceivers.isEmpty(), "the native registry is empty after release");
        }
        int blockedBefore = blockedDeliveries();
        int inboundBefore = inboundAttempts();
        int failuresBefore = failureCount();
        int deliveryBefore = com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver.delivered;
        int effectsBefore = app.receiverRegisterEffects;
        int removalsBefore = app.receiverUnregisterEffects;
        Intent intent = new Intent(ACTION);
        ((android.content.BroadcastReceiver) wrapper).onReceive(app, intent);
        int blockedAfter = blockedDeliveries();
        int inboundAfter = inboundAttempts();
        int failuresAfter = failureCount();
        result.put("mode", mode)
            .put("originalDeliveries",
                com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver.delivered - deliveryBefore)
            .put("extrasReads", intent.extrasRead)
            .put("blockedDelta", blockedAfter - blockedBefore)
            .put("inboundDelta", inboundAfter - inboundBefore)
            .put("failureDelta", failuresAfter - failuresBefore)
            .put("registerEffects", app.receiverRegisterEffects - effectsBefore)
            .put("removalEffects", app.receiverUnregisterEffects - removalsBefore);
        require(com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver.delivered
            == deliveryBefore, "the original receiver must not be delivered to");
        require(intent.extrasRead == 0, "the extras getter must never be read");
        require(blockedAfter - blockedBefore == 1, "exactly one blocked delivery");
        require(inboundAfter - inboundBefore == 1, "exactly one inbound attempt");
        require(failuresAfter - failuresBefore == 1, "exactly one recorded failure");
        require(app.receiverRegisterEffects == effectsBefore,
            "no native registration effect is invented");
        require(app.receiverUnregisterEffects == removalsBefore,
            "no native removal effect is invented");
        org.json.JSONArray inbound = inboundRecords();
        org.json.JSONObject last = inbound.getJSONObject(inbound.length() - 1);
        result.put("inboundAction", last.optString("action"))
            .put("inboundNativeClass", last.optString("nativeClass"));
        require(ACTION.equals(last.optString("action")),
            "the correct action is recorded on the inbound attempt");
        require(last.optString("nativeClass").endsWith("LebIpcReceiver"),
            "the original native class is recorded on the inbound attempt");
    }

    private static void boundaryIpcOpen(JSONObject result) throws Exception {
        ipcDelivery(result, "boundary-ipc-open");
    }

    private static void boundaryIpcClosing(JSONObject result) throws Exception {
        ipcDelivery(result, "boundary-ipc-closing");
    }

    // --- A5 owned main-work lifetime --------------------------------------

    private static int pendingOwnedWork() throws Exception {
        return GuardedReaderApplication.captureReceipt().optInt("pendingOwnedWork");
    }

    /** A queued item abandoned by its caller never runs and retires itself. */
    private static void a5CancelQueuedAcquire(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        android.os.Handler.hold();
        final Throwable[] callerError = {null};
        final boolean[] flagInside = {false};
        Thread caller = new Thread(() -> {
            try {
                GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
            } catch (Throwable error) {
                callerError[0] = error;
                flagInside[0] = Thread.currentThread().isInterrupted();
            }
        }, "a5-cancel-caller");
        caller.start();
        boolean queued = android.os.Handler.awaitQueued(5000);
        caller.interrupt();
        caller.join(10000);
        // The caller has exited, but the main observation has not run yet.
        int pendingAfterExit = pendingOwnedWork();
        boolean aliveAfterExit = caller.isAlive();
        int observeAttemptsBefore = (Integer) observableField(observable,
            "observerObserveAttempts");
        int observeEffectsBefore = (Integer) observableField(observable,
            "observerObserveEffects");
        android.os.Handler.flush();
        boolean idle = android.os.Handler.awaitIdle(10000);
        int pendingAfterIdle = pendingOwnedWork();
        int observeAttemptsAfter = (Integer) observableField(observable,
            "observerObserveAttempts");
        int observeEffectsAfter = (Integer) observableField(observable,
            "observerObserveEffects");
        result.put("queued", queued).put("pendingAfterExit", pendingAfterExit)
            .put("aliveAfterExit", aliveAfterExit)
            .put("callerError", callerError[0] == null ? "none"
                : FieldOracleFreeChain.describe(callerError[0]))
            .put("idle", idle).put("pendingAfterIdle", pendingAfterIdle)
            .put("observeAttempts", observeAttemptsAfter - observeAttemptsBefore)
            .put("observeEffects", observeEffectsAfter - observeEffectsBefore)
            .put("interrupted", flagInside[0])
            .put("captureFailed", GuardedReaderApplication.captureFailed());
        require(queued, "the work must be queued before the caller exits");
        require(!aliveAfterExit, "the interrupted caller has exited");
        require(pendingAfterExit == 1,
            "the abandoned item stays tracked until the main observation acknowledges it");
        require(callerError[0] instanceof InterruptedException,
            "the caller observes its own interruption");
        require(flagInside[0], "the caller interrupt flag is preserved");
        require(idle, "the main observation actually ran and acknowledged idle");
        require(pendingAfterIdle == 0, "the item retires after the real acknowledgement");
        require(observeAttemptsAfter - observeAttemptsBefore == 0,
            "an abandoned queued item never reaches the native observe attempt");
        require(observeEffectsAfter - observeEffectsBefore == 0,
            "an abandoned queued item never reaches the native observe effect");
        require(GuardedReaderApplication.captureFailed(),
            "an interrupted wait visibly fails the capture");
    }

    /** Direct MAIN execution is tracked through the same owned lifetime. */
    private static void a5DirectMainTracked(JSONObject result) throws Exception {
        GuardedReaderApplication app = new GuardedReaderApplication();
        final java.util.concurrent.CountDownLatch metadataEntered =
            new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch metadataRelease =
            new java.util.concurrent.CountDownLatch(1);
        // A delegating loader that holds ONLY the Pair metadata on MAIN.
        ClassLoader held = new ClassLoader(loader()) {
            @Override protected Class<?> loadClass(String name, boolean resolve)
                    throws ClassNotFoundException {
                if ("kotlin.Pair".equals(name)) {
                    metadataEntered.countDown();
                    try {
                        metadataRelease.await(10, java.util.concurrent.TimeUnit.SECONDS);
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                    }
                }
                return super.loadClass(name, resolve);
            }
        };
        GuardedReaderApplication.arm(app, held);
        final int[] pendingDuring = {-1};
        final boolean[] onMain = {false};
        final Throwable[] beginError = {null};
        final java.util.concurrent.CountDownLatch outerDone =
            new java.util.concurrent.CountDownLatch(1);
        boolean posted = new android.os.Handler(android.os.Looper.getMainLooper()).post(() -> {
            try {
                onMain[0] = android.os.Looper.myLooper() == android.os.Looper.getMainLooper();
                GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
            } catch (Throwable error) {
                beginError[0] = error;
            } finally {
                outerDone.countDown();
            }
        });
        boolean entered = metadataEntered.await(10, java.util.concurrent.TimeUnit.SECONDS);
        // The body is running on MAIN right now: pending must be visible.
        pendingDuring[0] = pendingOwnedWork();
        JSONObject releaseWhileRunning = GuardedReaderApplication.releaseProcessResources();
        metadataRelease.countDown();
        boolean finished = outerDone.await(15000, java.util.concurrent.TimeUnit.SECONDS);
        Object observable = liveObservableForTest();
        int observeEffects = (Integer) observableField(observable, "observerObserveEffects");
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        result.put("posted", posted).put("entered", entered).put("onMain", onMain[0])
            .put("pendingDuring", pendingDuring[0])
            .put("releaseWhileRunning", releaseWhileRunning.optBoolean("closed"))
            .put("finished", finished)
            .put("beginError", beginError[0] == null ? "none"
                : FieldOracleFreeChain.describe(beginError[0]))
            .put("observeEffects", observeEffects)
            .put("retryClosed", retry.optBoolean("closed"));
        require(posted && entered, "the outer MAIN callback really entered the body");
        require(onMain[0], "the body actually ran on MAIN");
        require(pendingDuring[0] == 1,
            "direct MAIN work is visible while it is running");
        require(!releaseWhileRunning.optBoolean("closed"),
            "a release during the running body is not a closure");
        require(finished, "the held body finished after the metadata was released");
        require(beginError[0] != null,
            "the body was refused because the lifetime was already closing");
        require(observeEffects == 0,
            "no native observer effect is attached after closing");
        require(retry.optBoolean("closed"), "the later real retry closes");
    }

    /** A refused enqueue visibly fails the capture. */
    private static void a5EnqueueRefused(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        android.os.Handler.refuseNext();
        Throwable thrown = faulted(() -> GuardedReaderApplication.beginSaveObservation(
            "http://book/1", "http://book/1/c1"));
        int pending = pendingOwnedWork();
        result.put("thrown", thrown != null).put("pending", pending)
            .put("nativeEffects", app.receiverRegisterEffects)
            .put("captureFailed", GuardedReaderApplication.captureFailed());
        require(thrown != null, "a refused enqueue is rethrown to the caller");
        require(pending == 0, "a refused enqueue retires its item");
        require(app.receiverRegisterEffects == 0, "no native effect happened");
        require(GuardedReaderApplication.captureFailed(),
            "a refused enqueue visibly fails the capture");
    }

    /** A body error is retained with its cause and retires the item. */
    private static void a5BodyErrorRetained(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        final RuntimeException original = new IllegalStateException("A5_BODY_ERROR",
            new IllegalArgumentException("A5_BODY_NESTED"));
        original.addSuppressed(new IllegalStateException("A5_BODY_SUPPRESSED"));
        final java.util.concurrent.CountDownLatch bodyEntered =
            new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch bodyRelease =
            new java.util.concurrent.CountDownLatch(1);
        // The approved focused host seam: the existing private runOnMain.
        java.lang.reflect.Method runOnMain =
            GuardedReaderApplication.class.getDeclaredMethod("runOnMain", java.util.concurrent.Callable.class);
        runOnMain.setAccessible(true);
        final Throwable[] callerError = {null};
        Thread caller = new Thread(() -> {
            try {
                runOnMain.invoke(app, (java.util.concurrent.Callable<JSONObject>) () -> {
                    bodyEntered.countDown();
                    try {
                        bodyRelease.await(10, java.util.concurrent.TimeUnit.SECONDS);
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                    }
                    throw original;
                });
            } catch (Throwable error) {
                callerError[0] = error;
            }
        }, "a5-body-caller");
        android.os.Handler.hold();
        caller.start();
        boolean queued = android.os.Handler.awaitQueued(5000);
        // Start the body first, so it is genuinely running when the waiter exits.
        android.os.Handler.flush();
        boolean entered = bodyEntered.await(10000, java.util.concurrent.TimeUnit.MILLISECONDS);
        caller.interrupt();
        caller.join(10000);
        int pendingAfterExit = pendingOwnedWork();
        // Now let the already-running body throw, after the caller has exited.
        bodyRelease.countDown();
        boolean idle = android.os.Handler.awaitIdle(10000);
        int pendingAfterIdle = pendingOwnedWork();
        String failures = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").toString();
        result.put("queued", queued).put("entered", entered)
            .put("pendingAfterExit", pendingAfterExit)
            .put("idle", idle).put("pendingAfterIdle", pendingAfterIdle)
            .put("callerError", callerError[0] == null ? "none"
                : FieldOracleFreeChain.describe(callerError[0]))
            .put("failures", failures);
        require(queued, "the body was queued before the caller exited");
        require(!caller.isAlive(), "the interrupted caller has exited");
        require(pendingAfterExit == 1,
            "the queued body stays tracked after the caller exits");
        require(entered, "the held body actually started after the flush");
        require(idle, "the body finished and the main thread is idle");
        require(pendingAfterIdle == 0, "the failed body retires its item");
        require(failures.contains("A5_BODY_ERROR") && failures.contains("A5_BODY_NESTED")
            && failures.contains("A5_BODY_SUPPRESSED"),
            "the executing boundary records the complete late body graph");
    }

    /** Many real work cycles all retire: value-key semantics, no leak. */
    private static void a5ManyCyclesRetire(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        int cycles = 130;
        for (int i = 0; i < cycles; i++) {
            GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
            GuardedReaderApplication.endSaveObservation(0);
        }
        int pending = pendingOwnedWork();
        result.put("cycles", cycles).put("pending", pending);
        require(pending == 0, "every completed cycle retires its item");
        // Each cycle intentionally carries no event, so the capture failure is
        // the expected A2 disposition; only retirement is asserted here.
    }

    /** A real lifecycle acquisition held before its effect blocks false closure. */
    private static void a5NativeInflightLifecycle(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        final java.util.concurrent.CountDownLatch entered =
            new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch release =
            new java.util.concurrent.CountDownLatch(1);
        Application.class.getField("lifecycleEntered").set(null, entered);
        Application.class.getField("lifecycleHeld").set(null, release);
        final Object callback = approvedCallback();
        final Throwable[] firstError = {null};
        Thread first = new Thread(() -> {
            try {
                app.registerActivityLifecycleCallbacks(
                    (Application.ActivityLifecycleCallbacks) callback);
            } catch (Throwable error) {
                firstError[0] = error;
            }
        }, "a5-native-inflight");
        first.start();
        boolean enteredOk;
        try {
            enteredOk = entered.await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            JSONObject release1 = GuardedReaderApplication.releaseProcessResources();
            result.put("entered", enteredOk).put("firstClosed", release1.optBoolean("closed"))
                .put("nativeEffectsWhileHeld", app.lifecycleRegisterEffects);
            require(enteredOk, "the native acquisition must be held before its effect");
            require(!release1.optBoolean("closed"),
                "a lifetime with an in-flight acquisition is not closed");
            require(app.lifecycleRegisterEffects == 0,
                "the held acquisition has not effected yet");
        } finally {
            release.countDown();
            Application.class.getField("lifecycleEntered").set(null, null);
            Application.class.getField("lifecycleHeld").set(null, null);
            first.join(10000);
        }
        result.put("firstError", firstError[0] == null ? "none"
                : FieldOracleFreeChain.describe(firstError[0]))
            .put("firstAlive", first.isAlive())
            .put("nativeEffects", app.lifecycleRegisterEffects)
            .put("nativeHeld", app.nativeCallbacks.size());
        require(firstError[0] == null, "the held acquisition completes normally");
        require(!first.isAlive(), "the acquisition thread terminated");
        require(app.lifecycleRegisterEffects == 1, "the acquisition really effected");
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        result.put("retryClosed", retry.optBoolean("closed"))
            .put("nativeAfter", app.nativeCallbacks.size());
        require(retry.optBoolean("closed"),
            "the later real retry closes once the acquisition is known");
        require(app.nativeCallbacks.isEmpty(),
            "the retry actually removes the native callback");
        require(!ownedCallback(callback), "the retry clears the owned callback");
    }

    /** A marker alone never proves the queue drained. */
    /**
     * A queued removal is interrupted before MAIN starts; the healthy typed
     * prestate is proven first, and the later real retry closes the owned
     * observer with an actual native removal.
     */
    private static void a5QueuedRemovalInterrupt(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        // The approved typed Pair on the controlled MAIN thread, so the removal
        // path is reached with a healthy prestate instead of an off-MAIN failure.
        deliver("http://book/1", "http://book/1/c1");
        JSONObject prestate = GuardedReaderApplication.captureReceipt();
        int attemptsBefore = a5NativeObserverAttempts(observable);
        int effectsBefore = a5NativeObserverEffects(observable);
        android.os.Handler.hold();
        final Throwable[] callerError = {null};
        final boolean[] flagInside = {false};
        Thread caller = new Thread(() -> {
            try {
                GuardedReaderApplication.endSaveObservation(0);
            } catch (Throwable error) {
                callerError[0] = error;
                flagInside[0] = Thread.currentThread().isInterrupted();
            }
        }, "a5-removal-caller");
        caller.start();
        boolean queued = android.os.Handler.awaitQueued(5000);
        caller.interrupt();
        boolean joined = a5JoinBounded(caller, 10000);
        int pendingAfterExit = pendingOwnedWork();
        android.os.Handler.flush();
        boolean idle = android.os.Handler.awaitIdle(10000);
        int pendingAfterIdle = pendingOwnedWork();
        int attemptsAfterFlush = a5NativeObserverAttempts(observable);
        int effectsAfterFlush = a5NativeObserverEffects(observable);
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        int attemptsAfterRetry = a5NativeObserverAttempts(observable);
        int effectsAfterRetry = a5NativeObserverEffects(observable);
        int nativeAfterRetry = a5NativeObserverCount(observable);
        result.put("preEvents", prestate.optInt("saveEvents"))
            .put("preObserving", prestate.optBoolean("observing"))
            .put("preCaptureFailed", prestate.optBoolean("captureFailed"))
            .put("queued", queued).put("joined", joined)
            .put("pendingAfterExit", pendingAfterExit)
            .put("attemptsBeforeFlush", attemptsAfterFlush - attemptsBefore)
            .put("effectsBeforeFlush", effectsAfterFlush - effectsBefore)
            .put("idle", idle).put("pendingAfterIdle", pendingAfterIdle)
            .put("attemptsAfterRetry", attemptsAfterRetry - attemptsBefore)
            .put("effectsAfterRetry", effectsAfterRetry - effectsBefore)
            .put("nativeAfterRetry", nativeAfterRetry)
            .put("callerError", callerError[0] == null ? "none"
                : FieldOracleFreeChain.describe(callerError[0]))
            .put("interruptFlagInside", flagInside[0])
            .put("retryClosed", retry.optBoolean("closed"))
            .put("captureFailed", GuardedReaderApplication.captureFailed());
        require(prestate.optBoolean("observing") && prestate.optInt("saveEvents") == 1
            && !prestate.optBoolean("captureFailed"),
            "the typed MAIN event leaves a healthy prestate before the interruption");
        require(queued, "the removal work was queued");
        require(joined, "the interrupted caller exited");
        require(pendingAfterExit == 1,
            "the queued removal stays owned before the main acknowledgement");
        require(attemptsAfterFlush - attemptsBefore == 0
            && effectsAfterFlush - effectsBefore == 0,
            "no native removal happened before the flush");
        require(flagInside[0], "the caller's own interrupt flag is preserved");
        require(callerError[0] instanceof InterruptedException,
            "the original interruption is retained");
        require(idle, "the main thread reached idle");
        require(pendingAfterIdle == 0, "the inert acknowledgement retires the item");
        require(attemptsAfterRetry - attemptsBefore == 1
            && effectsAfterRetry - effectsBefore == 1,
            "the real retry makes exactly one native removal attempt and effect");
        require(nativeAfterRetry == 0, "the retry leaves the native observer registry empty");
        require(retry.optBoolean("closed"), "the later real retry genuinely closes");
        require(pendingOwnedWork() == 0, "the owned work is empty after the retry");
        require(GuardedReaderApplication.captureFailed(),
            "the interruption visibly fails the capture");
    }

    /** The real unchanged 30000 ms expiry, never accelerated. */
    private static void a5RealTimeoutQueued(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        android.os.Handler.hold();
        long started = System.nanoTime();
        Throwable thrown = null;
        try {
            GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        } catch (Throwable error) {
            thrown = error;
        }
        long elapsedMillis = (System.nanoTime() - started) / 1000000L;
        int pendingAfterExpiry = pendingOwnedWork();
        int observeEffects = (Integer) observableField(observable, "observerObserveEffects");
        boolean interruptedInside = Thread.currentThread().isInterrupted();
        String chain = thrown == null ? "none" : FieldOracleFreeChain.describe(thrown);
        android.os.Handler.flush();
        boolean idle = android.os.Handler.awaitIdle(10000);
        int pendingAfterIdle = pendingOwnedWork();
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        result.put("elapsedMillis", elapsedMillis).put("thrown", thrown != null)
            .put("type", thrown == null ? "none" : thrown.getClass().getName())
            .put("chain", chain)
            .put("pendingAfterExpiry", pendingAfterExpiry)
            .put("observeEffects", observeEffects)
            .put("interrupted", interruptedInside)
            .put("idle", idle).put("pendingAfterIdle", pendingAfterIdle)
            .put("retryClosed", retry.optBoolean("closed"))
            .put("captureFailed", GuardedReaderApplication.captureFailed());
        require(elapsedMillis >= 30000L, "the real unchanged deadline actually elapsed");
        require(thrown instanceof IllegalStateException,
            "the expiry surfaces as the actual deadline failure type");
        require(chain.contains("main-thread work did not complete"),
            "the actual deadline reason is retained");
        require(!interruptedInside, "the expiry is a deadline, not an interruption");
        require(pendingAfterExpiry == 1,
            "the timed-out work stays tracked until the inert acknowledgement");
        require(observeEffects == 0, "no native observer effect happened");
        require(idle, "the main thread reached idle");
        require(pendingAfterIdle == 0, "the inert acknowledgement retires it");
        require(retry.optBoolean("closed"), "the honest cleanup closes");
        require(GuardedReaderApplication.captureFailed(),
            "the deadline visibly fails the capture");
    }

    /** A genuine before-enqueue fault, with real native cancellation acknowledgement. */
    private static void a5PostThrowBefore(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        java.lang.reflect.Method runOnMain =
            GuardedReaderApplication.class.getDeclaredMethod(
                "runOnMain", java.util.concurrent.Callable.class);
        runOnMain.setAccessible(true);

        // ---- Positive 1: throw before the native enqueue, cancellation succeeds.
        RuntimeException original = new IllegalStateException("A5_BEFORE_POST",
            new IllegalArgumentException("A5_BEFORE_NESTED"));
        original.addSuppressed(new IllegalStateException("A5_BEFORE_SUPPRESSED"));
        android.os.Handler.resetNativeReadouts();
        android.os.Handler.beforePostFault = original;
        final boolean[] bodyRan = {false};
        Throwable thrown = null;
        try {
            runOnMain.invoke(app, (java.util.concurrent.Callable<JSONObject>) () -> {
                bodyRan[0] = true;
                return new JSONObject();
            });
        } catch (Throwable error) {
            thrown = error instanceof java.lang.reflect.InvocationTargetException
                ? error.getCause() : error;
        } finally {
            android.os.Handler.beforePostFault = null;
        }
        int pending = pendingOwnedWork();
        int postCalls = android.os.Handler.nativePostCalls;
        int cancelCalls = android.os.Handler.nativeCancelCalls;
        boolean sameOwner = android.os.Handler.lastPostOwner != null
            && android.os.Handler.lastPostOwner == android.os.Handler.lastCancelOwner;
        boolean sameCallback = android.os.Handler.lastPostedCallback != null
            && android.os.Handler.lastPostedCallback == android.os.Handler.lastCancelledCallback;
        String failures = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").toString();
        String chain = thrown == null ? "none" : FieldOracleFreeChain.describe(thrown);
        result.put("identity", thrown == original).put("chain", chain)
            .put("bodyRan", bodyRan[0]).put("pending", pending)
            .put("postCalls", postCalls).put("cancelCalls", cancelCalls)
            .put("sameOwner", sameOwner).put("sameCallback", sameCallback)
            .put("failures", failures);
        require(thrown == original, "the original before-enqueue fault reaches the caller");
        require(chain.contains("A5_BEFORE_POST") && chain.contains("A5_BEFORE_NESTED")
            && chain.contains("A5_BEFORE_SUPPRESSED"),
            "the complete before-enqueue graph reaches the caller");
        require(!bodyRan[0], "the body never ran for a before-enqueue fault");
        require(postCalls == 1 && cancelCalls == 1,
            "the same actual Handler received the post and the cancellation");
        require(sameOwner, "the native cancellation used the exact same Handler");
        require(sameCallback, "the native cancellation used the exact same callback");
        require(pending == 0, "a successful void cancellation retires the item");
        require(failures.contains("A5_BEFORE_POST"),
            "the before-enqueue fault is retained in the capture");

        // ---- Positive 2: accepted by the native queue, cancelled before it starts.
        RuntimeException lateFault = new IllegalStateException("A5_ACCEPTED_THEN_CANCELLED");
        android.os.Handler.hold();
        android.os.Handler.resetNativeReadouts();
        android.os.Handler.afterPostFault = lateFault;
        final boolean[] bodyRanLate = {false};
        Throwable lateThrown = null;
        int acceptedBeforeCancel;
        int acceptedAfterCancel;
        try {
            runOnMain.invoke(app, (java.util.concurrent.Callable<JSONObject>) () -> {
                bodyRanLate[0] = true;
                return new JSONObject();
            });
        } catch (Throwable error) {
            lateThrown = error instanceof java.lang.reflect.InvocationTargetException
                ? error.getCause() : error;
        } finally {
            android.os.Handler.afterPostFault = null;
        }
        acceptedAfterCancel = android.os.Handler.nativePendingCount();
        int latePostCalls = android.os.Handler.nativePostCalls;
        int lateCancelCalls = android.os.Handler.nativeCancelCalls;
        boolean lateSameOwner = android.os.Handler.lastPostOwner != null
            && android.os.Handler.lastPostOwner == android.os.Handler.lastCancelOwner;
        boolean lateSameCallback = android.os.Handler.lastPostedCallback != null
            && android.os.Handler.lastPostedCallback == android.os.Handler.lastCancelledCallback;
        int pendingLate = pendingOwnedWork();
        android.os.Handler.flush();
        boolean idle = android.os.Handler.awaitIdle(10000);
        result.put("lateIdentity", lateThrown == lateFault)
            .put("lateBodyRan", bodyRanLate[0])
            .put("latePostCalls", latePostCalls).put("lateCancelCalls", lateCancelCalls)
            .put("lateSameOwner", lateSameOwner).put("lateSameCallback", lateSameCallback)
            .put("nativeQueueAfterCancel", acceptedAfterCancel)
            .put("pendingLate", pendingLate).put("idle", idle);
        require(lateThrown == lateFault,
            "the accepted-then-cancelled original fault reaches the caller");
        require(latePostCalls == 1 && lateCancelCalls == 1,
            "the native queue accepted the callback and the removal was invoked");
        require(lateSameOwner && lateSameCallback,
            "the removal used the exact same Handler and callback that were posted");
        require(acceptedAfterCancel == 0,
            "the real callback cancellation emptied the native queue before the flush");
        require(pendingLate == 0,
            "the acknowledged cancellation retires the item before the flush");
        require(idle, "the main thread reached idle");
        require(!bodyRanLate[0],
            "the flush and idle never delivered the cancelled callback or its body");

        // ---- Preserved: the native cancellation itself fails, honestly unclosed.
        RuntimeException cancelFailure = new IllegalStateException("A5_CANCEL_FAILED");
        android.os.Handler.beforePostFault = original;
        android.os.Handler.removeFault = cancelFailure;
        Throwable failedThrown = null;
        try {
            GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        } catch (Throwable error) {
            failedThrown = error;
        } finally {
            android.os.Handler.beforePostFault = null;
            android.os.Handler.removeFault = null;
        }
        int failedPending = pendingOwnedWork();
        boolean exactSuppressed = false;
        if (failedThrown != null) {
            for (Throwable suppressed : failedThrown.getSuppressed()) {
                if (suppressed == cancelFailure) exactSuppressed = true;
            }
        }
        String failedChain = failedThrown == null ? "none"
            : FieldOracleFreeChain.describe(failedThrown);
        result.put("cancelIdentity", failedThrown == original)
            .put("exactCancelSuppressed", exactSuppressed)
            .put("cancelChain", failedChain)
            .put("failedPending", failedPending);
        require(failedThrown == original,
            "the original post fault remains the primary failure");
        require(exactSuppressed,
            "the exact native cancellation failure is retained as a suppressed cause");
        require(failedChain.contains("A5_CANCEL_FAILED"),
            "the cancellation failure is visible in the retained graph");
        require(failedPending == 1,
            "a failed native cancellation keeps the item tracked, not falsely retired");
    }

    /** A throwing post after the body STARTED must never retire the running work. */
    private static void a5PostThrowAfterRunning(JSONObject result) throws Exception {
        GuardedReaderApplication app = new GuardedReaderApplication();
        final java.util.concurrent.CountDownLatch bodyEntered =
            new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch bodyRelease =
            new java.util.concurrent.CountDownLatch(1);
        // A loader that holds ONLY the Pair metadata; readiness never loads it.
        ClassLoader held = new ClassLoader(loader()) {
            @Override protected Class<?> loadClass(String name, boolean resolve)
                    throws ClassNotFoundException {
                if ("kotlin.Pair".equals(name)) {
                    // The actual guarded body signals that it started.
                    android.os.Handler.afterPostStarted.countDown();
                    bodyEntered.countDown();
                    try {
                        bodyRelease.await(30, java.util.concurrent.TimeUnit.SECONDS);
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                    }
                }
                return super.loadClass(name, resolve);
            }
        };
        GuardedReaderApplication.arm(app, held);
        RuntimeException original = new IllegalStateException("A5_AFTER_POST",
            new IllegalArgumentException("A5_AFTER_NESTED"));
        original.addSuppressed(new IllegalStateException("A5_AFTER_SUPPRESSED"));
        android.os.Handler.afterPostStarted =
            new java.util.concurrent.CountDownLatch(1);
        android.os.Handler.afterPostFault = original;
        final Throwable[] callerError = {null};
        Thread caller = new Thread(() -> {
            try {
                GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
            } catch (Throwable error) {
                callerError[0] = error;
            }
        }, "a5-after-caller");
        caller.start();
        boolean started = bodyEntered.await(20, java.util.concurrent.TimeUnit.SECONDS);
        boolean joined = a5JoinBounded(caller, 20000);
        int pendingWhileHeld = pendingOwnedWork();
        JSONObject releaseWhileHeld = GuardedReaderApplication.releaseProcessResources();
        Object observable = liveObservableForTest();
        int observeEffects = (Integer) observableField(observable, "observerObserveEffects");
        bodyRelease.countDown();
        boolean idle = android.os.Handler.awaitIdle(20000);
        int pendingAfterFinish = pendingOwnedWork();
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        android.os.Handler.afterPostFault = null;
        android.os.Handler.afterPostStarted = null;
        String chain = callerError[0] == null ? "none"
            : FieldOracleFreeChain.describe(callerError[0]);
        result.put("started", started).put("joined", joined)
            .put("pendingWhileHeld", pendingWhileHeld)
            .put("releaseWhileHeld", releaseWhileHeld.optBoolean("closed"))
            .put("observeEffects", observeEffects)
            .put("idle", idle).put("pendingAfterFinish", pendingAfterFinish)
            .put("chain", chain).put("retryClosed", retry.optBoolean("closed"));
        require(started, "the real guarded body started and is held on Pair metadata");
        require(joined, "the waiting caller exited on the original post fault");
        require(chain.contains("A5_AFTER_POST") && chain.contains("A5_AFTER_NESTED")
            && chain.contains("A5_AFTER_SUPPRESSED"),
            "the complete after-enqueue graph reaches the caller");
        require(pendingWhileHeld == 1,
            "a throwing post after the body started never retires the running work");
        require(!releaseWhileHeld.optBoolean("closed"),
            "the held body keeps the lifetime honestly unclosed");
        require(observeEffects == 0, "no native observer effect is attached after closing");
        require(idle, "the controlled release finished the body");
        require(pendingAfterFinish == 0, "the running work self-retires on completion");
        require(retry.optBoolean("closed"), "the real retry closes");
    }

    /** A marker is not a transitive drain of later descendant work. */
    private static void a5MarkerNotDrain(JSONObject result) throws Exception {
        GuardedReaderApplication app = new GuardedReaderApplication();
        final java.util.concurrent.CountDownLatch pairHeld =
            new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch pairRelease =
            new java.util.concurrent.CountDownLatch(1);
        ClassLoader heldLoader = new ClassLoader(loader()) {
            @Override protected Class<?> loadClass(String name, boolean resolve)
                    throws ClassNotFoundException {
                if ("kotlin.Pair".equals(name)) {
                    pairHeld.countDown();
                    try {
                        pairRelease.await(30, java.util.concurrent.TimeUnit.SECONDS);
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                    }
                }
                return super.loadClass(name, resolve);
            }
        };
        GuardedReaderApplication.arm(app, heldLoader);
        final Throwable[] descendantError = {null};
        final Thread[] descendant = {null};
        final JSONObject[] fenceResult = {null};
        android.os.Handler.hold();
        // The real fence marker is submitted FIRST, so it is ordered ahead of the
        // descendant and can complete while the descendant body is still held.
        Thread fenceThread = new Thread(() -> {
            try {
                fenceResult[0] = GuardedReaderApplication.fenceMainLooper(30000);
            } catch (Throwable error) {
                descendantError[0] = error;
            }
        }, "a5-marker-fence");
        fenceThread.start();
        boolean markerQueued = android.os.Handler.awaitQueued(20000);
        // The real tracked descendant is enqueued AFTER the marker.
        descendant[0] = new Thread(() -> {
            try {
                GuardedReaderApplication.beginSaveObservation(
                    "http://book/1", "http://book/1/c1");
            } catch (Throwable error) {
                descendantError[0] = error;
            }
        }, "a5-marker-descendant");
        descendant[0].start();
        boolean bodyHeld = false;
        android.os.Handler.flush();
        boolean fenceJoined = a5JoinBounded(fenceThread, 30000);
        bodyHeld = pairHeld.await(30, java.util.concurrent.TimeUnit.SECONDS);
        boolean markerCompleted = fenceResult[0] != null
            && fenceResult[0].optBoolean("completed");
        int pendingWhileHeld = pendingOwnedWork();
        JSONObject releaseWhileHeld = GuardedReaderApplication.releaseProcessResources();
        pairRelease.countDown();
        boolean joined = a5JoinBounded(descendant[0], 30000);
        boolean idle = android.os.Handler.awaitIdle(10000);
        int pendingAfter = pendingOwnedWork();
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        result.put("markerQueued", markerQueued).put("fenceJoined", fenceJoined)
            .put("bodyHeld", bodyHeld)
            .put("markerCompleted", markerCompleted)
            .put("pendingWhileHeld", pendingWhileHeld)
            .put("releaseWhileHeld", releaseWhileHeld.optBoolean("closed"))
            .put("joined", joined).put("idle", idle)
            .put("pendingAfter", pendingAfter)
            .put("descendantError", descendantError[0] == null ? "none"
                : FieldOracleFreeChain.describe(descendantError[0]))
            .put("retryClosed", retry.optBoolean("closed"));
        require(markerQueued, "the real fence marker was actually enqueued");
        require(fenceJoined, "the fence thread completed");
        require(markerCompleted, "the real fence marker completed");
        require(bodyHeld, "the descendant body is actually held");
        require(pendingWhileHeld == 1,
            "the marker is not a transitive drain: the descendant stays tracked");
        require(!releaseWhileHeld.optBoolean("closed"),
            "a completed marker plus a held descendant is not a closure");
        require(joined, "the descendant thread finished");
        require(idle, "the main thread reached idle");
        require(pendingAfter == 0, "the genuine finish retires the descendant");
        require(retry.optBoolean("closed"), "the real retry closes");
    }

    /** A real lifecycle removal held before its effect blocks false closure. */
    private static void a5NativeLifecycleRemoveBefore(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        final Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        final java.util.concurrent.CountDownLatch entered =
            new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch release =
            new java.util.concurrent.CountDownLatch(1);
        Application.class.getField("lifecycleRemoveEntered").set(app, entered);
        Application.class.getField("lifecycleRemoveHeld").set(app, release);
        final Throwable[] firstError = {null};
        Thread first = new Thread(() -> {
            try {
                app.unregisterActivityLifecycleCallbacks(
                    (Application.ActivityLifecycleCallbacks) callback);
            } catch (Throwable error) {
                firstError[0] = error;
            }
        }, "a5-native-remove-before");
        first.start();
        boolean enteredOk;
        JSONObject firstRelease;
        boolean firstAliveWhileHeld;
        int attemptsAtHold;
        int attemptsAfterFirstRelease;
        int effectsAfterFirstRelease;
        int nativeWhileHeld;
        boolean nativeExactWhileHeld;
        boolean ownedWhileHeld;
        boolean firstClosed;
        int remainingOwnedWhileHeld;
        int removedWhileHeld;
        String firstFailures;
        try {
            enteredOk = entered.await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            attemptsAtHold = app.lifecycleUnregisterAttempts;
            firstRelease = GuardedReaderApplication.releaseProcessResources();
            firstAliveWhileHeld = first.isAlive();
            attemptsAfterFirstRelease = app.lifecycleUnregisterAttempts;
            effectsAfterFirstRelease = app.lifecycleUnregisterEffects;
            nativeWhileHeld = app.nativeCallbacks.size();
            nativeExactWhileHeld = app.nativeCallbacks.containsKey(callback);
            ownedWhileHeld = ownedCallback(callback);
            firstClosed = firstRelease.optBoolean("closed");
            remainingOwnedWhileHeld =
                firstRelease.optInt("remainingOwnedLifecycleCallbacks");
            removedWhileHeld = firstRelease.optInt("removedLifecycleCallbacks");
            firstFailures = firstRelease.optJSONArray("removalFailures").toString();
        } finally {
            release.countDown();
            Application.class.getField("lifecycleRemoveEntered").set(app, null);
            Application.class.getField("lifecycleRemoveHeld").set(app, null);
            first.join(10000);
        }
        boolean firstAlive = first.isAlive();
        String firstChain = firstError[0] == null ? "none"
            : FieldOracleFreeChain.describe(firstError[0]);
        int attemptsAfterAck = app.lifecycleUnregisterAttempts;
        int effectsAfterAck = app.lifecycleUnregisterEffects;
        int nativeAfterAck = app.nativeCallbacks.size();
        boolean ownedAfterAck = ownedCallback(callback);
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        boolean retryClosed = retry.optBoolean("closed");
        int attemptsAfterRetry = app.lifecycleUnregisterAttempts;
        int effectsAfterRetry = app.lifecycleUnregisterEffects;
        int nativeAfterRetry = app.nativeCallbacks.size();
        boolean ownedAfterRetry = ownedCallback(callback);
        boolean captureFailed = GuardedReaderApplication.captureFailed();
        result.put("callbackIdentity", System.identityHashCode(callback))
            .put("entered", enteredOk)
            .put("firstAliveWhileHeld", firstAliveWhileHeld)
            .put("attemptsAtHold", attemptsAtHold)
            .put("attemptsAfterFirstRelease", attemptsAfterFirstRelease)
            .put("effectsAfterFirstRelease", effectsAfterFirstRelease)
            .put("nativeWhileHeld", nativeWhileHeld)
            .put("nativeExactWhileHeld", nativeExactWhileHeld)
            .put("ownedWhileHeld", ownedWhileHeld)
            .put("firstClosed", firstClosed)
            .put("remainingOwnedWhileHeld", remainingOwnedWhileHeld)
            .put("removedWhileHeld", removedWhileHeld)
            .put("firstFailures", firstFailures)
            .put("firstAlive", firstAlive)
            .put("firstError", firstChain)
            .put("attemptsAfterAck", attemptsAfterAck)
            .put("effectsAfterAck", effectsAfterAck)
            .put("nativeAfterAck", nativeAfterAck)
            .put("ownedAfterAck", ownedAfterAck)
            .put("retryClosed", retryClosed)
            .put("attemptsAfterRetry", attemptsAfterRetry)
            .put("effectsAfterRetry", effectsAfterRetry)
            .put("nativeAfterRetry", nativeAfterRetry)
            .put("ownedAfterRetry", ownedAfterRetry)
            .put("captureFailed", captureFailed);
        require(enteredOk, "the native removal was held before its effect");
        require(firstAliveWhileHeld, "the removal worker is still alive while held");
        require(attemptsAtHold == 1, "exactly one native removal attempt was made");
        require(attemptsAfterFirstRelease == 1,
            "the final release made no duplicate native removal attempt");
        require(effectsAfterFirstRelease == 0,
            "the held removal has not effected yet");
        require(nativeWhileHeld == 1 && nativeExactWhileHeld,
            "the exact callback remains in the native registry");
        require(ownedWhileHeld, "the guard still owns the exact callback");
        require(!firstClosed,
            "a lifetime with an in-flight removal is not closed");
        require(remainingOwnedWhileHeld == 1 && removedWhileHeld == 0,
            "the refusal retains the owned callback without a removal");
        require(firstFailures.contains("lifecycle native call still in flight at release"),
            "the refusal records the actual in-flight reason");
        require(!firstAlive, "the held removal thread terminated");
        if (firstError[0] instanceof Exception) throw (Exception) firstError[0];
        if (firstError[0] != null) throw new AssertionError(firstError[0]);
        require(attemptsAfterAck == 1 && effectsAfterAck == 1,
            "the actual first acknowledgement is one attempt and one effect");
        require(nativeAfterAck == 0 && !ownedAfterAck,
            "the acknowledgement empties the native and owned registries");
        require(retryClosed, "the real retry closes after the acknowledgement");
        require(attemptsAfterRetry == 1 && effectsAfterRetry == 1,
            "the retry closes without another native removal call");
        require(nativeAfterRetry == 0 && !ownedAfterRetry,
            "the retry leaves native and owned empty");
        require(captureFailed,
            "the unsafe-cleanup refusal keeps the capture failure sticky");
    }

    // --- A5 Native acquisition/removal/terminal join -----------------------

    /**
     * Read-only: the guard's native-call reservation set, under either name.
     *
     * <p>The set covered acquisitions only before it also covered removals, so
     * the previous name stays readable for honest old-source sensitivity.
     */
    private static java.util.Set<?> a5NativeCalls() throws Exception {
        for (String name : new String[] {"nativeCalls", "acquiringNative"}) {
            try {
                java.lang.reflect.Field field =
                    GuardedReaderApplication.class.getDeclaredField(name);
                field.setAccessible(true);
                return (java.util.Set<?>) field.get(null);
            } catch (NoSuchFieldException missing) {
                // The previous reservation-set name is supported on purpose.
            }
        }
        throw new AssertionError("the guard has no native-call reservation set");
    }

    /** Read-only: whether the guard currently reserves this exact native handle. */
    private static boolean a5NativeBusy(Object handle) throws Exception {
        return handle != null && a5NativeCalls().contains(handle);
    }

    /** Installs one bounded one-shot native hold on the given public fixture fields. */
    private static java.util.concurrent.CountDownLatch[] a5NativeHold(Object target,
            String enteredName, String heldName) throws Exception {
        java.util.concurrent.CountDownLatch entered =
            new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.CountDownLatch held =
            new java.util.concurrent.CountDownLatch(1);
        setObservableField(target, enteredName, entered);
        setObservableField(target, heldName, held);
        return new java.util.concurrent.CountDownLatch[] {entered, held};
    }

    /** Clears the one-shot native hold so the boundary cannot be held again. */
    private static void a5NativeClearHold(Object target, String enteredName,
            String heldName) throws Exception {
        setObservableField(target, enteredName, null);
        setObservableField(target, heldName, null);
    }

    /** Starts one real final release on its own thread, so a block is observable. */
    private static Thread a5NativeStartRelease(final JSONObject[] receipt,
            final Throwable[] error) {
        Thread release = new Thread(() -> {
            try {
                receipt[0] = GuardedReaderApplication.releaseProcessResources();
            } catch (Throwable thrown) {
                error[0] = thrown;
            }
        }, "a5-native-release");
        release.start();
        return release;
    }

    private static int a5NativeObserverAttempts(Object observable) throws Exception {
        return (Integer) observableField(observable, "observerRemoveAttempts");
    }

    private static int a5NativeObserverEffects(Object observable) throws Exception {
        return (Integer) observableField(observable, "observerRemoveEffects");
    }

    private static int a5NativeObserverCount(Object observable) throws Exception {
        return ((java.util.Map<?, ?>) observableField(observable, "nativeObservers")).size();
    }

    /**
     * A receiver acquisition held before its effect blocks false closure while
     * the unrelated observer and lifecycle domains still clean.
     */
    private static void a5NativeReceiverAcquire(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        final com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(app, "registerEntered", "registerHeld");
        final Throwable[] registerError = {null};
        Thread first = new Thread(() -> {
            try {
                app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
            } catch (Throwable error) {
                registerError[0] = error;
            }
        }, "a5-native-receiver-acquire");
        first.start();
        boolean enteredOk;
        boolean aliveWhileHeld;
        boolean busyWhileHeld;
        boolean ownedWhileHeld;
        int attemptsAtHold;
        int effectsAtHold;
        int nativeWhileHeld;
        JSONObject firstRelease;
        boolean firstClosed;
        int remainingWhileHeld;
        int removedWhileHeld;
        String firstFailures;
        boolean observerClosedWhileHeld;
        int removedCallbacksWhileHeld;
        int nativeCallbacksWhileHeld;
        try {
            enteredOk = hold[0].await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            Object wrapper = storedWrapper(app, receiver);
            attemptsAtHold = app.receiverRegisterAttempts;
            effectsAtHold = app.receiverRegisterEffects;
            nativeWhileHeld = app.nativeReceivers.size();
            busyWhileHeld = a5NativeBusy(wrapper);
            ownedWhileHeld = wrapper != null && ownedReceiverList().contains(wrapper);
            firstRelease = GuardedReaderApplication.releaseProcessResources();
            aliveWhileHeld = first.isAlive();
            firstClosed = firstRelease.optBoolean("closed");
            remainingWhileHeld = firstRelease.optInt("remainingOwnedReceivers");
            removedWhileHeld = firstRelease.optInt("removedReceivers");
            firstFailures = firstRelease.optJSONArray("removalFailures").toString();
            JSONObject observerClose = firstRelease.optJSONObject("observerClose");
            JSONObject observerRemoval = observerClose == null ? null
                : observerClose.optJSONObject("removal");
            observerClosedWhileHeld = observerRemoval != null
                && observerRemoval.optBoolean("removed");
            removedCallbacksWhileHeld = firstRelease.optInt("removedLifecycleCallbacks");
            nativeCallbacksWhileHeld = app.nativeCallbacks.size();
        } finally {
            hold[1].countDown();
            a5NativeClearHold(app, "registerEntered", "registerHeld");
            first.join(10000);
        }
        boolean firstAlive = first.isAlive();
        String firstError = registerError[0] == null ? "none"
            : FieldOracleFreeChain.describe(registerError[0]);
        int attemptsAfterAck = app.receiverRegisterAttempts;
        int effectsAfterAck = app.receiverRegisterEffects;
        int nativeAfterAck = app.nativeReceivers.size();
        boolean ownedAfterAck = ownedReceiverList().contains(storedWrapper(app, receiver));
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        int attemptsAfterRetry = app.receiverRegisterAttempts;
        int effectsAfterRetry = app.receiverUnregisterEffects;
        int nativeAfterRetry = app.nativeReceivers.size();
        boolean ownedAfterRetry = ownedReceiverList().contains(storedWrapper(app, receiver));
        result.put("entered", enteredOk).put("aliveWhileHeld", aliveWhileHeld)
            .put("busyWhileHeld", busyWhileHeld).put("ownedWhileHeld", ownedWhileHeld)
            .put("attemptsAtHold", attemptsAtHold).put("effectsAtHold", effectsAtHold)
            .put("nativeWhileHeld", nativeWhileHeld)
            .put("firstClosed", firstClosed)
            .put("remainingWhileHeld", remainingWhileHeld)
            .put("removedWhileHeld", removedWhileHeld)
            .put("firstFailures", firstFailures)
            .put("observerClosedWhileHeld", observerClosedWhileHeld)
            .put("removedCallbacksWhileHeld", removedCallbacksWhileHeld)
            .put("nativeCallbacksWhileHeld", nativeCallbacksWhileHeld)
            .put("firstAlive", firstAlive).put("firstError", firstError)
            .put("attemptsAfterAck", attemptsAfterAck)
            .put("effectsAfterAck", effectsAfterAck)
            .put("nativeAfterAck", nativeAfterAck)
            .put("ownedAfterAck", ownedAfterAck)
            .put("retryClosed", retry.optBoolean("closed"))
            .put("attemptsAfterRetry", attemptsAfterRetry)
            .put("effectsAfterRetry", effectsAfterRetry)
            .put("nativeAfterRetry", nativeAfterRetry)
            .put("ownedAfterRetry", ownedAfterRetry);
        require(enteredOk, "the receiver acquisition was held before its effect");
        require(aliveWhileHeld, "the acquisition worker is still inside the native call");
        require(attemptsAtHold == 1 && effectsAtHold == 0 && nativeWhileHeld == 0,
            "the held acquisition made one attempt and no effect");
        require(busyWhileHeld, "the exact wrapper is reserved while its call is alive");
        require(ownedWhileHeld, "the exact wrapper is owned before the effect");
        require(!firstClosed, "a lifetime with an in-flight receiver call is not closed");
        require(remainingWhileHeld == 1 && removedWhileHeld == 0,
            "the refusal retains the owned wrapper without a removal");
        require(firstFailures.contains("receiver native call still in flight at release"),
            "the refusal records the actual in-flight reason");
        require(observerClosedWhileHeld,
            "the unrelated observer domain still cleans");
        require(removedCallbacksWhileHeld == 1 && nativeCallbacksWhileHeld == 0,
            "the unrelated lifecycle domain still cleans");
        require(!firstAlive, "the held acquisition thread terminated");
        require("none".equals(firstError), "the held acquisition completes normally");
        require(attemptsAfterAck == 1 && effectsAfterAck == 1,
            "the actual acquisition acknowledgement is one attempt and one effect");
        require(nativeAfterAck == 1 && ownedAfterAck,
            "the acknowledged acquisition is owned until a real removal");
        require(retry.optBoolean("closed"), "the real retry closes after the acknowledgement");
        require(attemptsAfterRetry == 1 && effectsAfterRetry == 1,
            "the retry closes without another native registration call");
        require(nativeAfterRetry == 0 && !ownedAfterRetry,
            "the retry leaves native and owned empty");
    }

    /**
     * An observer acquisition held on MAIN before its effect is detected before
     * another MAIN removal is scheduled, so unrelated domains still clean.
     */
    private static void a5NativeObserverAcquire(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        Object observable = liveObservableForTest();
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(observable, "observeEntered", "observeHeld");
        final Throwable[] beginError = {null};
        Thread caller = new Thread(() -> {
            try {
                GuardedReaderApplication.beginSaveObservation(
                    "http://book/1", "http://book/1/c1");
            } catch (Throwable error) {
                beginError[0] = error;
            }
        }, "a5-native-observer-acquire");
        caller.start();
        boolean enteredOk;
        boolean busyWhileHeld;
        boolean tupleWhileHeld;
        int pendingWhileHeld;
        int observeAttemptsWhileHeld;
        int observeEffectsWhileHeld;
        int postsBefore;
        int postsAfter;
        boolean callerAliveWhileHeld;
        Thread release = null;
        boolean prompt;
        JSONObject firstRelease;
        boolean firstClosed;
        boolean observingWhileHeld;
        String firstFailures;
        int removedReceiversWhileHeld;
        int removedCallbacksWhileHeld;
        final JSONObject[] receipt = {null};
        final Throwable[] releaseError = {null};
        try {
            enteredOk = hold[0].await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            Object observer = staleObserver();
            busyWhileHeld = a5NativeBusy(observer);
            tupleWhileHeld = io.liber.oracle.nested.BoundaryInspection.observerTupleExact;
            pendingWhileHeld = pendingOwnedWork();
            observeAttemptsWhileHeld =
                (Integer) observableField(observable, "observerObserveAttempts");
            observeEffectsWhileHeld =
                (Integer) observableField(observable, "observerObserveEffects");
            postsBefore = android.os.Handler.nativePostCalls;
            release = a5NativeStartRelease(receipt, releaseError);
            prompt = a5JoinBounded(release, 5000);
            postsAfter = android.os.Handler.nativePostCalls;
            callerAliveWhileHeld = caller.isAlive();
            firstRelease = receipt[0];
            firstClosed = firstRelease != null && firstRelease.optBoolean("closed");
            observingWhileHeld =
                GuardedReaderApplication.captureReceipt().optBoolean("observing");
            firstFailures = firstRelease == null ? ""
                : firstRelease.optJSONArray("removalFailures").toString();
            removedReceiversWhileHeld =
                firstRelease == null ? -1 : firstRelease.optInt("removedReceivers");
            removedCallbacksWhileHeld = firstRelease == null ? -1
                : firstRelease.optInt("removedLifecycleCallbacks");
        } finally {
            hold[1].countDown();
            a5NativeClearHold(observable, "observeEntered", "observeHeld");
            caller.join(40000);
            if (release != null) release.join(40000);
        }
        boolean callerAlive = caller.isAlive();
        String beginChain = beginError[0] == null ? "none"
            : FieldOracleFreeChain.describe(beginError[0]);
        int observeEffectsAfter = (Integer) observableField(observable, "observerObserveEffects");
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        int attemptsAfterRetry = a5NativeObserverAttempts(observable);
        int effectsAfterRetry = a5NativeObserverEffects(observable);
        int nativeAfterRetry = a5NativeObserverCount(observable);
        result.put("entered", enteredOk).put("busyWhileHeld", busyWhileHeld)
            .put("tupleWhileHeld", tupleWhileHeld)
            .put("pendingWhileHeld", pendingWhileHeld)
            .put("observeAttemptsWhileHeld", observeAttemptsWhileHeld)
            .put("observeEffectsWhileHeld", observeEffectsWhileHeld)
            .put("postsBefore", postsBefore).put("postsAfter", postsAfter)
            .put("prompt", prompt).put("callerAliveWhileHeld", callerAliveWhileHeld)
            .put("firstClosed", firstClosed)
            .put("observingWhileHeld", observingWhileHeld)
            .put("firstFailures", firstFailures)
            .put("removedReceiversWhileHeld", removedReceiversWhileHeld)
            .put("removedCallbacksWhileHeld", removedCallbacksWhileHeld)
            .put("releaseError", releaseError[0] == null ? "none"
                : FieldOracleFreeChain.describe(releaseError[0]))
            .put("callerAlive", callerAlive).put("beginChain", beginChain)
            .put("observeEffectsAfter", observeEffectsAfter)
            .put("retryClosed", retry.optBoolean("closed"))
            .put("attemptsAfterRetry", attemptsAfterRetry)
            .put("effectsAfterRetry", effectsAfterRetry)
            .put("nativeAfterRetry", nativeAfterRetry);
        require(enteredOk, "the observer acquisition was held before its effect");
        require(callerAliveWhileHeld, "the acquisition waiter is still waiting on MAIN");
        require(busyWhileHeld, "the exact observer is reserved while its call is alive");
        require(tupleWhileHeld, "the exact observable/observer/remove tuple is reserved");
        require(pendingWhileHeld == 1, "the acquisition stays tracked while it runs");
        require(observeAttemptsWhileHeld == 1 && observeEffectsWhileHeld == 0,
            "the held acquisition made one attempt and no effect");
        require(releaseError[0] == null, "the final release itself did not throw");
        require(prompt, "the release detects the known busy observer without waiting");
        require(postsAfter == postsBefore,
            "no second MAIN removal is scheduled behind the blocked MAIN call");
        require(!firstClosed, "a lifetime with an in-flight observer call is not closed");
        require(observingWhileHeld, "the uncertain observation stays owned");
        require(firstFailures.contains("native call still in flight at release"),
            "the refusal records the actual in-flight reason");
        require(removedReceiversWhileHeld == 1 && removedCallbacksWhileHeld == 1,
            "the unrelated receiver and lifecycle domains still clean");
        require(!callerAlive, "the acquisition waiter terminated after the effect");
        require("none".equals(beginChain), "the held acquisition completes normally");
        require(observeEffectsAfter == 1, "the acquisition really effected after the hold");
        require(retry.optBoolean("closed"), "the later real retry closes");
        require(attemptsAfterRetry == 1 && effectsAfterRetry == 1,
            "the retry performs the one real removal attempt and effect");
        require(nativeAfterRetry == 0, "the retry leaves the native observer registry empty");
    }

    /** A real receiver removal held before its effect blocks false closure. */
    private static void a5NativeReceiverRemoveBefore(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        final com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        final Object wrapper = storedWrapper(app, receiver);
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(app, "receiverRemoveEntered", "receiverRemoveHeld");
        final Throwable[] firstError = {null};
        Thread first = new Thread(() -> {
            try {
                app.unregisterReceiver(receiver);
            } catch (Throwable error) {
                firstError[0] = error;
            }
        }, "a5-native-receiver-remove-before");
        first.start();
        boolean enteredOk;
        int attemptsAtHold;
        int effectsAtHold;
        boolean busyWhileHeld;
        boolean ownedWhileHeld;
        JSONObject firstRelease;
        boolean firstClosed;
        int remainingWhileHeld;
        int removedWhileHeld;
        String firstFailures;
        boolean aliveWhileHeld;
        try {
            enteredOk = hold[0].await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            attemptsAtHold = app.receiverUnregisterAttempts;
            effectsAtHold = app.receiverUnregisterEffects;
            busyWhileHeld = a5NativeBusy(wrapper);
            ownedWhileHeld = ownedReceiverList().contains(wrapper);
            firstRelease = GuardedReaderApplication.releaseProcessResources();
            aliveWhileHeld = first.isAlive();
            firstClosed = firstRelease.optBoolean("closed");
            remainingWhileHeld = firstRelease.optInt("remainingOwnedReceivers");
            removedWhileHeld = firstRelease.optInt("removedReceivers");
            firstFailures = firstRelease.optJSONArray("removalFailures").toString();
        } finally {
            hold[1].countDown();
            a5NativeClearHold(app, "receiverRemoveEntered", "receiverRemoveHeld");
            first.join(10000);
        }
        boolean firstAlive = first.isAlive();
        String firstChain = firstError[0] == null ? "none"
            : FieldOracleFreeChain.describe(firstError[0]);
        int attemptsAfterAck = app.receiverUnregisterAttempts;
        int effectsAfterAck = app.receiverUnregisterEffects;
        int nativeAfterAck = app.nativeReceivers.size();
        boolean ownedAfterAck = ownedReceiverList().contains(wrapper);
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        int attemptsAfterRetry = app.receiverUnregisterAttempts;
        int effectsAfterRetry = app.receiverUnregisterEffects;
        int nativeAfterRetry = app.nativeReceivers.size();
        result.put("entered", enteredOk).put("aliveWhileHeld", aliveWhileHeld)
            .put("attemptsAtHold", attemptsAtHold).put("effectsAtHold", effectsAtHold)
            .put("busyWhileHeld", busyWhileHeld).put("ownedWhileHeld", ownedWhileHeld)
            .put("firstClosed", firstClosed)
            .put("remainingWhileHeld", remainingWhileHeld)
            .put("removedWhileHeld", removedWhileHeld)
            .put("firstFailures", firstFailures)
            .put("firstAlive", firstAlive).put("firstError", firstChain)
            .put("attemptsAfterAck", attemptsAfterAck)
            .put("effectsAfterAck", effectsAfterAck)
            .put("nativeAfterAck", nativeAfterAck)
            .put("ownedAfterAck", ownedAfterAck)
            .put("retryClosed", retry.optBoolean("closed"))
            .put("attemptsAfterRetry", attemptsAfterRetry)
            .put("effectsAfterRetry", effectsAfterRetry)
            .put("nativeAfterRetry", nativeAfterRetry);
        require(enteredOk, "the receiver removal was held before its effect");
        require(aliveWhileHeld, "the removal worker is still inside the native call");
        require(attemptsAtHold == 1 && effectsAtHold == 0,
            "exactly one native removal attempt was made and it has not effected");
        require(busyWhileHeld, "the exact wrapper is reserved while its removal is alive");
        require(ownedWhileHeld, "the guard still owns the exact wrapper");
        require(!firstClosed, "a lifetime with an in-flight removal is not closed");
        require(remainingWhileHeld == 1 && removedWhileHeld == 0,
            "the refusal retains the owned wrapper without a removal");
        require(firstFailures.contains("receiver native call still in flight at release"),
            "the refusal records the actual in-flight reason");
        require(!firstAlive, "the held removal thread terminated");
        require("none".equals(firstChain), "the held removal completes normally");
        require(attemptsAfterAck == 1 && effectsAfterAck == 1,
            "the actual first acknowledgement is one attempt and one effect");
        require(nativeAfterAck == 0 && !ownedAfterAck,
            "the acknowledgement empties the native and owned registries");
        require(retry.optBoolean("closed"), "the real retry closes after the acknowledgement");
        require(attemptsAfterRetry == 1 && effectsAfterRetry == 1,
            "the retry closes without another native removal call");
        require(nativeAfterRetry == 0, "the retry leaves the native registry empty");
    }

    /** A real receiver removal held after its effect but before its return. */
    private static void a5NativeReceiverRemoveAfter(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        final com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        final Object wrapper = storedWrapper(app, receiver);
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(app, "receiverRemoveAfterEntered", "receiverRemoveAfterHeld");
        final Throwable[] firstError = {null};
        Thread first = new Thread(() -> {
            try {
                app.unregisterReceiver(receiver);
            } catch (Throwable error) {
                firstError[0] = error;
            }
        }, "a5-native-receiver-remove-after");
        first.start();
        boolean enteredOk;
        int attemptsAtHold;
        int effectsAtHold;
        int nativeWhileHeld;
        boolean busyWhileHeld;
        boolean ownedWhileHeld;
        JSONObject firstRelease;
        boolean firstClosed;
        int remainingWhileHeld;
        int removedWhileHeld;
        String firstFailures;
        boolean aliveWhileHeld;
        try {
            enteredOk = hold[0].await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            attemptsAtHold = app.receiverUnregisterAttempts;
            effectsAtHold = app.receiverUnregisterEffects;
            nativeWhileHeld = app.nativeReceivers.size();
            busyWhileHeld = a5NativeBusy(wrapper);
            ownedWhileHeld = ownedReceiverList().contains(wrapper);
            firstRelease = GuardedReaderApplication.releaseProcessResources();
            aliveWhileHeld = first.isAlive();
            firstClosed = firstRelease.optBoolean("closed");
            remainingWhileHeld = firstRelease.optInt("remainingOwnedReceivers");
            removedWhileHeld = firstRelease.optInt("removedReceivers");
            firstFailures = firstRelease.optJSONArray("removalFailures").toString();
        } finally {
            hold[1].countDown();
            a5NativeClearHold(app, "receiverRemoveAfterEntered", "receiverRemoveAfterHeld");
            first.join(10000);
        }
        boolean firstAlive = first.isAlive();
        String firstChain = firstError[0] == null ? "none"
            : FieldOracleFreeChain.describe(firstError[0]);
        int attemptsAfterAck = app.receiverUnregisterAttempts;
        int effectsAfterAck = app.receiverUnregisterEffects;
        int nativeAfterAck = app.nativeReceivers.size();
        boolean ownedAfterAck = ownedReceiverList().contains(wrapper);
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        int attemptsAfterRetry = app.receiverUnregisterAttempts;
        int effectsAfterRetry = app.receiverUnregisterEffects;
        int nativeAfterRetry = app.nativeReceivers.size();
        result.put("entered", enteredOk).put("aliveWhileHeld", aliveWhileHeld)
            .put("attemptsAtHold", attemptsAtHold).put("effectsAtHold", effectsAtHold)
            .put("nativeWhileHeld", nativeWhileHeld)
            .put("busyWhileHeld", busyWhileHeld).put("ownedWhileHeld", ownedWhileHeld)
            .put("firstClosed", firstClosed)
            .put("remainingWhileHeld", remainingWhileHeld)
            .put("removedWhileHeld", removedWhileHeld)
            .put("firstFailures", firstFailures)
            .put("firstAlive", firstAlive).put("firstError", firstChain)
            .put("attemptsAfterAck", attemptsAfterAck)
            .put("effectsAfterAck", effectsAfterAck)
            .put("nativeAfterAck", nativeAfterAck)
            .put("ownedAfterAck", ownedAfterAck)
            .put("retryClosed", retry.optBoolean("closed"))
            .put("attemptsAfterRetry", attemptsAfterRetry)
            .put("effectsAfterRetry", effectsAfterRetry)
            .put("nativeAfterRetry", nativeAfterRetry);
        require(enteredOk, "the receiver removal was held after its effect");
        require(aliveWhileHeld, "the removal worker is still inside the native call");
        require(attemptsAtHold == 1 && effectsAtHold == 1 && nativeWhileHeld == 0,
            "the held removal already effected once and the native handle is gone");
        require(busyWhileHeld, "the exact wrapper is reserved until its call returns");
        require(ownedWhileHeld, "ownership is retained until the call returns");
        require(!firstClosed, "a lifetime with an in-flight removal is not closed");
        require(remainingWhileHeld == 1 && removedWhileHeld == 0,
            "the refusal retains the owned wrapper without a removal");
        require(firstFailures.contains("receiver native call still in flight at release"),
            "the refusal records the actual in-flight reason");
        require(!firstAlive, "the held removal thread terminated");
        require("none".equals(firstChain), "the held removal completes normally");
        require(attemptsAfterAck == 1 && effectsAfterAck == 1,
            "the actual first acknowledgement is one attempt and one effect");
        require(nativeAfterAck == 0 && !ownedAfterAck,
            "the acknowledgement empties the native and owned registries");
        require(retry.optBoolean("closed"), "the real retry closes after the acknowledgement");
        require(attemptsAfterRetry == 1 && effectsAfterRetry == 1,
            "the retry closes without another native removal call");
        require(nativeAfterRetry == 0, "the retry leaves the native registry empty");
    }

    /** A real lifecycle removal held after its effect but before its return. */
    private static void a5NativeLifecycleRemoveAfter(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        final Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(app, "lifecycleRemoveAfterEntered", "lifecycleRemoveAfterHeld");
        final Throwable[] firstError = {null};
        Thread first = new Thread(() -> {
            try {
                app.unregisterActivityLifecycleCallbacks(
                    (Application.ActivityLifecycleCallbacks) callback);
            } catch (Throwable error) {
                firstError[0] = error;
            }
        }, "a5-native-lifecycle-remove-after");
        first.start();
        boolean enteredOk;
        int attemptsAtHold;
        int effectsAtHold;
        int nativeWhileHeld;
        boolean busyWhileHeld;
        boolean ownedWhileHeld;
        JSONObject firstRelease;
        boolean firstClosed;
        int remainingWhileHeld;
        int removedWhileHeld;
        String firstFailures;
        boolean aliveWhileHeld;
        try {
            enteredOk = hold[0].await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            attemptsAtHold = app.lifecycleUnregisterAttempts;
            effectsAtHold = app.lifecycleUnregisterEffects;
            nativeWhileHeld = app.nativeCallbacks.size();
            busyWhileHeld = a5NativeBusy(callback);
            ownedWhileHeld = ownedCallback(callback);
            firstRelease = GuardedReaderApplication.releaseProcessResources();
            aliveWhileHeld = first.isAlive();
            firstClosed = firstRelease.optBoolean("closed");
            remainingWhileHeld = firstRelease.optInt("remainingOwnedLifecycleCallbacks");
            removedWhileHeld = firstRelease.optInt("removedLifecycleCallbacks");
            firstFailures = firstRelease.optJSONArray("removalFailures").toString();
        } finally {
            hold[1].countDown();
            a5NativeClearHold(app, "lifecycleRemoveAfterEntered", "lifecycleRemoveAfterHeld");
            first.join(10000);
        }
        boolean firstAlive = first.isAlive();
        String firstChain = firstError[0] == null ? "none"
            : FieldOracleFreeChain.describe(firstError[0]);
        int attemptsAfterAck = app.lifecycleUnregisterAttempts;
        int effectsAfterAck = app.lifecycleUnregisterEffects;
        int nativeAfterAck = app.nativeCallbacks.size();
        boolean ownedAfterAck = ownedCallback(callback);
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        int attemptsAfterRetry = app.lifecycleUnregisterAttempts;
        int effectsAfterRetry = app.lifecycleUnregisterEffects;
        int nativeAfterRetry = app.nativeCallbacks.size();
        result.put("entered", enteredOk).put("aliveWhileHeld", aliveWhileHeld)
            .put("attemptsAtHold", attemptsAtHold).put("effectsAtHold", effectsAtHold)
            .put("nativeWhileHeld", nativeWhileHeld)
            .put("busyWhileHeld", busyWhileHeld).put("ownedWhileHeld", ownedWhileHeld)
            .put("firstClosed", firstClosed)
            .put("remainingWhileHeld", remainingWhileHeld)
            .put("removedWhileHeld", removedWhileHeld)
            .put("firstFailures", firstFailures)
            .put("firstAlive", firstAlive).put("firstError", firstChain)
            .put("attemptsAfterAck", attemptsAfterAck)
            .put("effectsAfterAck", effectsAfterAck)
            .put("nativeAfterAck", nativeAfterAck)
            .put("ownedAfterAck", ownedAfterAck)
            .put("retryClosed", retry.optBoolean("closed"))
            .put("attemptsAfterRetry", attemptsAfterRetry)
            .put("effectsAfterRetry", effectsAfterRetry)
            .put("nativeAfterRetry", nativeAfterRetry);
        require(enteredOk, "the lifecycle removal was held after its effect");
        require(aliveWhileHeld, "the removal worker is still inside the native call");
        require(attemptsAtHold == 1 && effectsAtHold == 1 && nativeWhileHeld == 0,
            "the held removal already effected once and the native handle is gone");
        require(busyWhileHeld, "the exact callback is reserved until its call returns");
        require(ownedWhileHeld, "ownership is retained until the call returns");
        require(!firstClosed, "a lifetime with an in-flight removal is not closed");
        require(remainingWhileHeld == 1 && removedWhileHeld == 0,
            "the refusal retains the owned callback without a removal");
        require(firstFailures.contains("lifecycle native call still in flight at release"),
            "the refusal records the actual in-flight reason");
        require(!firstAlive, "the held removal thread terminated");
        require("none".equals(firstChain), "the held removal completes normally");
        require(attemptsAfterAck == 1 && effectsAfterAck == 1,
            "the actual first acknowledgement is one attempt and one effect");
        require(nativeAfterAck == 0 && !ownedAfterAck,
            "the acknowledgement empties the native and owned registries");
        require(retry.optBoolean("closed"), "the real retry closes after the acknowledgement");
        require(attemptsAfterRetry == 1 && effectsAfterRetry == 1,
            "the retry closes without another native removal call");
        require(nativeAfterRetry == 0, "the retry leaves the native registry empty");
    }

    /**
     * A real observer removal held on MAIN before its effect is detected before
     * another MAIN removal is scheduled, and the late ACK still finalizes.
     */
    private static void a5NativeObserverRemoveBefore(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(observable, "removeEntered", "removeHeld");
        final Throwable[] callerError = {null};
        Thread caller = new Thread(() -> {
            try {
                GuardedReaderApplication.endSaveObservation(0);
            } catch (Throwable error) {
                callerError[0] = error;
            }
        }, "a5-native-observer-remove-before");
        caller.start();
        boolean enteredOk;
        boolean busyWhileHeld;
        String readOnlyState;
        boolean readOnlyBusy;
        int attemptsAtHold;
        int effectsAtHold;
        int nativeWhileHeld;
        boolean observingWhileHeld;
        int postsBefore;
        int postsAfter;
        boolean callerAliveWhileHeld;
        Thread release = null;
        boolean prompt;
        JSONObject firstRelease;
        boolean firstClosed;
        String firstFailures;
        final JSONObject[] receipt = {null};
        final Throwable[] releaseError = {null};
        try {
            enteredOk = hold[0].await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            Object observer = staleObserver();
            attemptsAtHold = a5NativeObserverAttempts(observable);
            effectsAtHold = a5NativeObserverEffects(observable);
            nativeWhileHeld = a5NativeObserverCount(observable);
            busyWhileHeld = a5NativeBusy(observer);
            // The read-only fixture inspection must agree with the direct read.
            readOnlyState = io.liber.oracle.nested.BoundaryInspection.nativeState();
            readOnlyBusy = io.liber.oracle.nested.BoundaryInspection.observerNativeBusy;
            observingWhileHeld =
                GuardedReaderApplication.captureReceipt().optBoolean("observing");
            postsBefore = android.os.Handler.nativePostCalls;
            release = a5NativeStartRelease(receipt, releaseError);
            prompt = a5JoinBounded(release, 5000);
            postsAfter = android.os.Handler.nativePostCalls;
            callerAliveWhileHeld = caller.isAlive();
            firstRelease = receipt[0];
            firstClosed = firstRelease != null && firstRelease.optBoolean("closed");
            firstFailures = firstRelease == null ? ""
                : firstRelease.optJSONArray("removalFailures").toString();
        } finally {
            hold[1].countDown();
            a5NativeClearHold(observable, "removeEntered", "removeHeld");
            caller.join(40000);
            if (release != null) release.join(40000);
        }
        boolean callerAlive = caller.isAlive();
        String callerChain = callerError[0] == null ? "none"
            : FieldOracleFreeChain.describe(callerError[0]);
        boolean idle = android.os.Handler.awaitIdle(10000);
        int attemptsAfterAck = a5NativeObserverAttempts(observable);
        int effectsAfterAck = a5NativeObserverEffects(observable);
        int nativeAfterAck = a5NativeObserverCount(observable);
        JSONObject repeat = GuardedReaderApplication.endSaveObservation(0);
        int attemptsAfterRepeat = a5NativeObserverAttempts(observable);
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        result.put("entered", enteredOk).put("busyWhileHeld", busyWhileHeld)
            .put("readOnlyState", readOnlyState).put("readOnlyBusy", readOnlyBusy)
            .put("attemptsAtHold", attemptsAtHold).put("effectsAtHold", effectsAtHold)
            .put("nativeWhileHeld", nativeWhileHeld)
            .put("observingWhileHeld", observingWhileHeld)
            .put("postsBefore", postsBefore).put("postsAfter", postsAfter)
            .put("prompt", prompt).put("callerAliveWhileHeld", callerAliveWhileHeld)
            .put("firstClosed", firstClosed).put("firstFailures", firstFailures)
            .put("releaseError", releaseError[0] == null ? "none"
                : FieldOracleFreeChain.describe(releaseError[0]))
            .put("callerAlive", callerAlive).put("callerChain", callerChain)
            .put("idle", idle)
            .put("attemptsAfterAck", attemptsAfterAck)
            .put("effectsAfterAck", effectsAfterAck)
            .put("nativeAfterAck", nativeAfterAck)
            .put("repeat", repeat)
            .put("attemptsAfterRepeat", attemptsAfterRepeat)
            .put("retryClosed", retry.optBoolean("closed"));
        require(enteredOk, "the observer removal was held before its effect");
        require(busyWhileHeld, "the exact observer is reserved while its removal is alive");
        require(readOnlyBusy && readOnlyState.startsWith("nativeCalls=1"),
            "the read-only fixture inspection sees the same single reservation");
        require(attemptsAtHold == 1 && effectsAtHold == 0 && nativeWhileHeld == 1,
            "the held removal made one attempt, no effect, and the observer is installed");
        require(observingWhileHeld, "the uncertain observation stays owned");
        require(releaseError[0] == null, "the final release itself did not throw");
        require(prompt, "the release detects the known busy observer without waiting");
        require(postsAfter == postsBefore,
            "no second MAIN removal is scheduled behind the blocked MAIN call");
        require(!firstClosed, "a lifetime with an in-flight removal is not closed");
        require(firstFailures.contains("native call still in flight at release"),
            "the refusal records the actual in-flight reason");
        require(!callerAlive, "the original removal caller terminated");
        require("none".equals(callerChain), "the held removal completes normally");
        require(idle, "the real removal body finished on MAIN");
        require(attemptsAfterAck == 1 && effectsAfterAck == 1,
            "the late ACK is exactly one attempt and one effect");
        require(nativeAfterAck == 0, "the observer really went away");
        require(repeat.optBoolean("alreadyClosed") && repeat.optBoolean("removed"),
            "the late ACK is the honest repeat proof");
        require(repeat.optInt("events") == 1 && !repeat.optBoolean("failed"),
            "the case validity survives the held removal");
        require(attemptsAfterRepeat == 1, "the repeat adds no native removal attempt");
        require(retry.optBoolean("closed"), "the later real release closes");
    }

    /**
     * A real observer removal held after its effect but before its bookkeeping:
     * the reservation is retained through the acknowledgement, so no second
     * native call and no false closure can happen.
     */
    private static void a5NativeObserverRemoveAfter(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(observable, "removeAfterEntered", "removeAfterHeld");
        final Throwable[] callerError = {null};
        Thread caller = new Thread(() -> {
            try {
                GuardedReaderApplication.endSaveObservation(0);
            } catch (Throwable error) {
                callerError[0] = error;
            }
        }, "a5-native-observer-remove-after");
        caller.start();
        boolean enteredOk;
        boolean busyWhileHeld;
        int attemptsAtHold;
        int effectsAtHold;
        int nativeWhileHeld;
        boolean observingWhileHeld;
        int postsBefore;
        int postsAfter;
        boolean callerAliveWhileHeld;
        Thread release = null;
        boolean prompt;
        JSONObject firstRelease;
        boolean firstClosed;
        String firstFailures;
        final JSONObject[] receipt = {null};
        final Throwable[] releaseError = {null};
        try {
            enteredOk = hold[0].await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            Object observer = staleObserver();
            attemptsAtHold = a5NativeObserverAttempts(observable);
            effectsAtHold = a5NativeObserverEffects(observable);
            nativeWhileHeld = a5NativeObserverCount(observable);
            busyWhileHeld = a5NativeBusy(observer);
            observingWhileHeld =
                GuardedReaderApplication.captureReceipt().optBoolean("observing");
            postsBefore = android.os.Handler.nativePostCalls;
            release = a5NativeStartRelease(receipt, releaseError);
            prompt = a5JoinBounded(release, 5000);
            postsAfter = android.os.Handler.nativePostCalls;
            callerAliveWhileHeld = caller.isAlive();
            firstRelease = receipt[0];
            firstClosed = firstRelease != null && firstRelease.optBoolean("closed");
            firstFailures = firstRelease == null ? ""
                : firstRelease.optJSONArray("removalFailures").toString();
        } finally {
            hold[1].countDown();
            a5NativeClearHold(observable, "removeAfterEntered", "removeAfterHeld");
            caller.join(40000);
            if (release != null) release.join(40000);
        }
        boolean callerAlive = caller.isAlive();
        String callerChain = callerError[0] == null ? "none"
            : FieldOracleFreeChain.describe(callerError[0]);
        boolean idle = android.os.Handler.awaitIdle(10000);
        int attemptsAfterAck = a5NativeObserverAttempts(observable);
        int effectsAfterAck = a5NativeObserverEffects(observable);
        int nativeAfterAck = a5NativeObserverCount(observable);
        JSONObject repeat = GuardedReaderApplication.endSaveObservation(0);
        int attemptsAfterRepeat = a5NativeObserverAttempts(observable);
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        result.put("entered", enteredOk).put("busyWhileHeld", busyWhileHeld)
            .put("attemptsAtHold", attemptsAtHold).put("effectsAtHold", effectsAtHold)
            .put("nativeWhileHeld", nativeWhileHeld)
            .put("observingWhileHeld", observingWhileHeld)
            .put("postsBefore", postsBefore).put("postsAfter", postsAfter)
            .put("prompt", prompt).put("callerAliveWhileHeld", callerAliveWhileHeld)
            .put("firstClosed", firstClosed).put("firstFailures", firstFailures)
            .put("releaseError", releaseError[0] == null ? "none"
                : FieldOracleFreeChain.describe(releaseError[0]))
            .put("callerAlive", callerAlive).put("callerChain", callerChain)
            .put("idle", idle)
            .put("attemptsAfterAck", attemptsAfterAck)
            .put("effectsAfterAck", effectsAfterAck)
            .put("nativeAfterAck", nativeAfterAck)
            .put("repeat", repeat)
            .put("attemptsAfterRepeat", attemptsAfterRepeat)
            .put("retryClosed", retry.optBoolean("closed"));
        require(enteredOk, "the observer removal was held after its effect");
        require(busyWhileHeld,
            "the reservation is retained through the acknowledgement bookkeeping");
        require(attemptsAtHold == 1 && effectsAtHold == 1 && nativeWhileHeld == 0,
            "the held removal already effected once and the observer is gone");
        require(observingWhileHeld, "the acknowledgement bookkeeping has not finished");
        require(releaseError[0] == null, "the final release itself did not throw");
        require(prompt, "the release detects the known busy observer without waiting");
        require(postsAfter == postsBefore,
            "no second MAIN removal is scheduled behind the blocked MAIN call");
        require(!firstClosed, "a lifetime with an in-flight removal is not closed");
        require(firstFailures.contains("native call still in flight at release"),
            "the refusal records the actual in-flight reason");
        require(!callerAlive, "the original removal caller terminated");
        require("none".equals(callerChain), "the held removal completes normally");
        require(idle, "the real removal body finished on MAIN");
        require(attemptsAfterAck == 1 && effectsAfterAck == 1,
            "the late ACK is exactly one attempt and one effect");
        require(nativeAfterAck == 0, "the observer really went away");
        require(repeat.optBoolean("alreadyClosed") && repeat.optBoolean("removed"),
            "the late ACK is the honest repeat proof");
        require(repeat.optInt("events") == 1 && !repeat.optBoolean("failed"),
            "the case validity survives the held removal");
        require(attemptsAfterRepeat == 1, "the repeat adds no native removal attempt");
        require(retry.optBoolean("closed"), "the later real release closes");
    }

    /**
     * A waiter interrupted while the real removal executes keeps its own
     * interruption, and the late ACK still finalizes the terminal facts.
     */
    private static void a5NativeObserverLateInterrupt(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(observable, "removeEntered", "removeHeld");
        final Throwable[] callerError = {null};
        final boolean[] flagInside = {false};
        Thread caller = new Thread(() -> {
            try {
                GuardedReaderApplication.endSaveObservation(0);
            } catch (Throwable error) {
                callerError[0] = error;
                flagInside[0] = Thread.currentThread().isInterrupted();
            }
        }, "a5-native-observer-late-interrupt");
        caller.start();
        boolean enteredOk;
        int attemptsAtHold;
        int effectsAtHold;
        boolean joined;
        try {
            enteredOk = hold[0].await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            attemptsAtHold = a5NativeObserverAttempts(observable);
            effectsAtHold = a5NativeObserverEffects(observable);
            caller.interrupt();
            joined = a5JoinBounded(caller, 10000);
        } finally {
            hold[1].countDown();
            a5NativeClearHold(observable, "removeEntered", "removeHeld");
            caller.join(40000);
        }
        boolean idle = android.os.Handler.awaitIdle(10000);
        int attemptsAfterAck = a5NativeObserverAttempts(observable);
        int effectsAfterAck = a5NativeObserverEffects(observable);
        int nativeAfterAck = a5NativeObserverCount(observable);
        JSONObject repeat = GuardedReaderApplication.endSaveObservation(0);
        int attemptsAfterRepeat = a5NativeObserverAttempts(observable);
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        result.put("entered", enteredOk)
            .put("attemptsAtHold", attemptsAtHold).put("effectsAtHold", effectsAtHold)
            .put("joined", joined)
            .put("callerChain", callerError[0] == null ? "none"
                : FieldOracleFreeChain.describe(callerError[0]))
            .put("interruptFlagInside", flagInside[0])
            .put("idle", idle)
            .put("attemptsAfterAck", attemptsAfterAck)
            .put("effectsAfterAck", effectsAfterAck)
            .put("nativeAfterAck", nativeAfterAck)
            .put("repeat", repeat)
            .put("attemptsAfterRepeat", attemptsAfterRepeat)
            .put("releaseClosed", release.optBoolean("closed"))
            .put("captureFailed", GuardedReaderApplication.captureFailed());
        require(enteredOk, "the real removal body was genuinely blocked");
        require(attemptsAtHold == 1 && effectsAtHold == 0,
            "the held removal made one attempt and no effect");
        require(joined, "the interrupted waiter exited");
        require(callerError[0] instanceof InterruptedException,
            "the waiter observes its own interruption");
        require(flagInside[0], "the waiter interrupt flag is preserved");
        require(GuardedReaderApplication.captureFailed(),
            "the interruption visibly fails the capture");
        require(idle, "the real removal body finished on MAIN");
        require(attemptsAfterAck == 1 && effectsAfterAck == 1,
            "the late ACK is exactly one attempt and one effect");
        require(nativeAfterAck == 0, "the observer really went away");
        require(repeat.optBoolean("alreadyClosed") && repeat.optBoolean("removed"),
            "the late ACK is the honest repeat proof");
        require(repeat.optInt("events") == 1 && !repeat.optBoolean("failed"),
            "the case validity survives the departed waiter");
        require(attemptsAfterRepeat == 1, "the repeat adds no native removal attempt");
        require(release.optBoolean("closed"), "the later real release closes");
    }

    /** The real unchanged 30000 ms removal deadline while the body is held. */
    private static void a5NativeObserverLateDeadline(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(observable, "removeEntered", "removeHeld");
        final Throwable[] callerError = {null};
        Thread caller = new Thread(() -> {
            try {
                GuardedReaderApplication.endSaveObservation(0);
            } catch (Throwable error) {
                callerError[0] = error;
            }
        }, "a5-native-observer-late-deadline");
        caller.start();
        boolean enteredOk;
        int attemptsAtHold;
        int effectsAtHold;
        long started;
        boolean joined;
        long elapsedMillis;
        Thread release = null;
        boolean prompt;
        JSONObject firstRelease;
        boolean firstClosed;
        String firstFailures;
        boolean busyWhileHeld;
        int attemptsWhileHeld;
        final JSONObject[] receipt = {null};
        final Throwable[] releaseError = {null};
        try {
            enteredOk = hold[0].await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            attemptsAtHold = a5NativeObserverAttempts(observable);
            effectsAtHold = a5NativeObserverEffects(observable);
            started = System.nanoTime();
            joined = a5JoinBounded(caller, 45000);
            elapsedMillis = (System.nanoTime() - started) / 1000000L;
            busyWhileHeld = a5NativeBusy(staleObserver());
            attemptsWhileHeld = a5NativeObserverAttempts(observable);
            release = a5NativeStartRelease(receipt, releaseError);
            prompt = a5JoinBounded(release, 5000);
            firstRelease = receipt[0];
            firstClosed = firstRelease != null && firstRelease.optBoolean("closed");
            firstFailures = firstRelease == null ? ""
                : firstRelease.optJSONArray("removalFailures").toString();
        } finally {
            hold[1].countDown();
            a5NativeClearHold(observable, "removeEntered", "removeHeld");
            caller.join(40000);
            if (release != null) release.join(40000);
        }
        boolean idle = android.os.Handler.awaitIdle(10000);
        int attemptsAfterAck = a5NativeObserverAttempts(observable);
        int effectsAfterAck = a5NativeObserverEffects(observable);
        int nativeAfterAck = a5NativeObserverCount(observable);
        JSONObject repeat = GuardedReaderApplication.endSaveObservation(0);
        int attemptsAfterRepeat = a5NativeObserverAttempts(observable);
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        String chain = callerError[0] == null ? "none"
            : FieldOracleFreeChain.describe(callerError[0]);
        result.put("entered", enteredOk)
            .put("attemptsAtHold", attemptsAtHold).put("effectsAtHold", effectsAtHold)
            .put("joined", joined).put("elapsedMillis", elapsedMillis)
            .put("callerType", callerError[0] == null ? "none"
                : callerError[0].getClass().getName())
            .put("callerChain", chain)
            .put("busyWhileHeld", busyWhileHeld)
            .put("attemptsWhileHeld", attemptsWhileHeld)
            .put("prompt", prompt).put("firstClosed", firstClosed)
            .put("firstFailures", firstFailures)
            .put("releaseError", releaseError[0] == null ? "none"
                : FieldOracleFreeChain.describe(releaseError[0]))
            .put("idle", idle)
            .put("attemptsAfterAck", attemptsAfterAck)
            .put("effectsAfterAck", effectsAfterAck)
            .put("nativeAfterAck", nativeAfterAck)
            .put("repeat", repeat)
            .put("attemptsAfterRepeat", attemptsAfterRepeat)
            .put("retryClosed", retry.optBoolean("closed"));
        require(enteredOk, "the real removal body was genuinely blocked");
        require(attemptsAtHold == 1 && effectsAtHold == 0,
            "the held removal made one attempt and no effect");
        require(joined, "the timed-out waiter exited");
        require(elapsedMillis >= 30000L, "the real unchanged deadline actually elapsed");
        require(callerError[0] instanceof IllegalStateException,
            "the expiry surfaces as the actual deadline failure type");
        require(chain.contains("main-thread work did not complete"),
            "the actual deadline reason is retained");
        require(!Thread.currentThread().isInterrupted(),
            "the expiry is a deadline, not an interruption");
        require(busyWhileHeld && attemptsWhileHeld == 1,
            "the resource stays busy and false after the waiter expired");
        require(releaseError[0] == null, "the final release itself did not throw");
        require(prompt, "the release detects the known busy observer without waiting");
        require(!firstClosed, "a lifetime with an in-flight removal is not closed");
        require(firstFailures.contains("native call still in flight at release"),
            "the refusal records the actual in-flight reason");
        require(idle, "the real removal body finished on MAIN");
        require(attemptsAfterAck == 1 && effectsAfterAck == 1,
            "the late ACK is exactly one attempt and one effect");
        require(nativeAfterAck == 0, "the observer really went away");
        require(repeat.optBoolean("alreadyClosed") && repeat.optBoolean("removed"),
            "the late ACK is the honest repeat proof");
        require(repeat.optInt("events") == 1 && !repeat.optBoolean("failed"),
            "the case validity survives the expired waiter");
        require(attemptsAfterRepeat == 1, "the repeat adds no native removal attempt");
        require(retry.optBoolean("closed"), "the later real release closes");
    }

    /** A late Native removal error after the caller exited keeps its full graph. */
    private static void a5NativeObserverLateError(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(observable, "removeEntered", "removeHeld");
        final Throwable[] callerError = {null};
        Thread caller = new Thread(() -> {
            try {
                GuardedReaderApplication.endSaveObservation(0);
            } catch (Throwable error) {
                callerError[0] = error;
            }
        }, "a5-native-observer-late-error");
        caller.start();
        boolean enteredOk;
        boolean joined;
        try {
            enteredOk = hold[0].await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            caller.interrupt();
            joined = a5JoinBounded(caller, 10000);
            RuntimeException original = new IllegalStateException("LATE_NATIVE_ERROR",
                new IllegalArgumentException("LATE_NATIVE_NESTED"));
            original.addSuppressed(new IllegalStateException("LATE_NATIVE_SUPPRESSED"));
            setObservableField(observable, "observerRemoveBeforeEffect", original);
        } finally {
            hold[1].countDown();
            a5NativeClearHold(observable, "removeEntered", "removeHeld");
            caller.join(40000);
        }
        boolean idle = android.os.Handler.awaitIdle(10000);
        String failures = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").toString();
        int attemptsAfterError = a5NativeObserverAttempts(observable);
        int effectsAfterError = a5NativeObserverEffects(observable);
        int nativeAfterError = a5NativeObserverCount(observable);
        boolean observingAfterError =
            GuardedReaderApplication.captureReceipt().optBoolean("observing");
        setObservableField(observable, "observerRemoveBeforeEffect", null);
        JSONObject retry = GuardedReaderApplication.endSaveObservation(0);
        int attemptsAfterRetry = a5NativeObserverAttempts(observable);
        int effectsAfterRetry = a5NativeObserverEffects(observable);
        int nativeAfterRetry = a5NativeObserverCount(observable);
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        result.put("entered", enteredOk).put("joined", joined)
            .put("callerChain", callerError[0] == null ? "none"
                : FieldOracleFreeChain.describe(callerError[0]))
            .put("idle", idle).put("failures", failures)
            .put("attemptsAfterError", attemptsAfterError)
            .put("effectsAfterError", effectsAfterError)
            .put("nativeAfterError", nativeAfterError)
            .put("observingAfterError", observingAfterError)
            .put("retry", retry)
            .put("attemptsAfterRetry", attemptsAfterRetry)
            .put("effectsAfterRetry", effectsAfterRetry)
            .put("nativeAfterRetry", nativeAfterRetry)
            .put("releaseClosed", release.optBoolean("closed"));
        require(enteredOk, "the real removal body was genuinely blocked");
        require(joined, "the interrupted caller exited before the error");
        require(idle, "the executing boundary finished on MAIN");
        require(failures.contains("LATE_NATIVE_ERROR"),
            "the late primary error is retained without a waiter");
        require(failures.contains("LATE_NATIVE_NESTED"),
            "the late nested cause is retained without a waiter");
        require(failures.contains("LATE_NATIVE_SUPPRESSED"),
            "the late suppressed error is retained without a waiter");
        require(attemptsAfterError == 1 && effectsAfterError == 0
            && nativeAfterError == 1 && observingAfterError,
            "the failed removal keeps the tuple and ownership uncertain");
        JSONObject retryRemoval = retry.optJSONObject("removal");
        require(retryRemoval != null && retryRemoval.optBoolean("removed"),
            "the real retry returns an actual Native ACK");
        require(retry.optInt("events") == 1 && !retry.optBoolean("failed"),
            "the retry carries the correct case proof");
        require(attemptsAfterRetry == 2 && effectsAfterRetry == 1,
            "the retry is a second real attempt with one effect");
        require(nativeAfterRetry == 0, "the retry really removed the observer");
        require(release.optBoolean("closed"), "the later real release closes");
    }

    /**
     * An entry-interrupted cleanup is consumed only for best effort: the posted
     * MAIN removal still runs, a mid-cleanup interrupt is recorded while the
     * later domains still clean, and the incoming flag is restored.
     */
    private static void a5NativeEntryInterruptedCleanup(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(observable, "removeEntered", "removeHeld");
        // The queued MAIN removal must not start before the entry interruption is
        // observed, so the best-effort wait is proven without a timing guess.
        android.os.Handler.hold();
        final JSONObject[] receipt = {null};
        final Throwable[] releaseError = {null};
        final boolean[] flagAfterCleanup = {false};
        Thread release = new Thread(() -> {
            Thread.currentThread().interrupt();
            try {
                receipt[0] = GuardedReaderApplication.releaseProcessResources();
                flagAfterCleanup[0] = Thread.currentThread().isInterrupted();
            } catch (Throwable thrown) {
                releaseError[0] = thrown;
            }
        }, "a5-native-entry-interrupted-cleanup");
        release.start();
        boolean queued = android.os.Handler.awaitQueued(10000);
        boolean stillWaiting = !a5JoinBounded(release, 1000);
        final boolean[] interruptedDuringCleanup = {false};
        Thread interrupter = new Thread(() -> {
            try {
                if (hold[0].await(10000, java.util.concurrent.TimeUnit.MILLISECONDS)) {
                    interruptedDuringCleanup[0] = true;
                    release.interrupt();
                }
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
        }, "a5-native-mid-cleanup-interrupt");
        interrupter.start();
        android.os.Handler.flush();
        boolean joined;
        JSONObject firstRelease;
        int attemptsDuringCleanup;
        int effectsDuringCleanup;
        int nativeReceiversAfter;
        int nativeCallbacksAfter;
        boolean closedDuringCleanup;
        String failuresDuringCleanup;
        boolean captureFailedDuringCleanup;
        try {
            joined = a5JoinBounded(release, 20000);
            firstRelease = receipt[0];
            attemptsDuringCleanup = a5NativeObserverAttempts(observable);
            effectsDuringCleanup = a5NativeObserverEffects(observable);
            nativeReceiversAfter = app.nativeReceivers.size();
            nativeCallbacksAfter = app.nativeCallbacks.size();
            closedDuringCleanup = firstRelease != null && firstRelease.optBoolean("closed");
            failuresDuringCleanup = GuardedReaderApplication.captureReceipt()
                .getJSONArray("failures").toString();
            captureFailedDuringCleanup = GuardedReaderApplication.captureFailed();
        } finally {
            hold[1].countDown();
            a5NativeClearHold(observable, "removeEntered", "removeHeld");
            interrupter.join(15000);
            release.join(40000);
        }
        boolean idle = android.os.Handler.awaitIdle(10000);
        int attemptsAfterAck = a5NativeObserverAttempts(observable);
        int effectsAfterAck = a5NativeObserverEffects(observable);
        int nativeAfterAck = a5NativeObserverCount(observable);
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        boolean retryClosed = retry.optBoolean("closed");
        boolean captureFailedAfterRetry = GuardedReaderApplication.captureFailed();
        result.put("queued", queued).put("stillWaiting", stillWaiting)
            .put("joined", joined)
            .put("interruptedDuringCleanup", interruptedDuringCleanup[0])
            .put("attemptsDuringCleanup", attemptsDuringCleanup)
            .put("effectsDuringCleanup", effectsDuringCleanup)
            .put("nativeReceiversAfter", nativeReceiversAfter)
            .put("nativeCallbacksAfter", nativeCallbacksAfter)
            .put("closedDuringCleanup", closedDuringCleanup)
            .put("failuresDuringCleanup", failuresDuringCleanup)
            .put("captureFailedDuringCleanup", captureFailedDuringCleanup)
            .put("flagAfterCleanup", flagAfterCleanup[0])
            .put("releaseError", releaseError[0] == null ? "none"
                : FieldOracleFreeChain.describe(releaseError[0]))
            .put("idle", idle)
            .put("attemptsAfterAck", attemptsAfterAck)
            .put("effectsAfterAck", effectsAfterAck)
            .put("nativeAfterAck", nativeAfterAck)
            .put("retryClosed", retryClosed)
            .put("captureFailedAfterRetry", captureFailedAfterRetry);
        require(queued, "the observer removal was really posted to MAIN");
        require(stillWaiting,
            "the entry interruption does not abort the best-effort cleanup wait");
        require(joined, "the cleanup thread terminated");
        require(releaseError[0] == null, "the final release itself did not throw");
        require(interruptedDuringCleanup[0],
            "a real interrupt was delivered while the cleanup was in progress");
        require(attemptsDuringCleanup == 1,
            "the entry-interrupted cleanup still reached the real observer removal");
        require(effectsDuringCleanup == 0, "the held removal has not effected yet");
        require(nativeReceiversAfter == 0 && nativeCallbacksAfter == 0,
            "the later receiver and lifecycle domains still cleaned");
        require(!closedDuringCleanup,
            "a mid-cleanup interruption is not reported as closure");
        require(failuresDuringCleanup.contains("interrupted waiting for main-thread work"),
            "the mid-cleanup interruption is recorded");
        require(captureFailedDuringCleanup, "the interruption fails the capture");
        require(flagAfterCleanup[0], "the incoming interrupt flag is restored after cleanup");
        require(idle, "the real removal body finished on MAIN");
        require(attemptsAfterAck == 1 && effectsAfterAck == 1,
            "the late ACK is exactly one attempt and one effect");
        require(nativeAfterAck == 0, "the observer really went away");
        require(retryClosed, "the later real retry closes the resources");
        require(captureFailedAfterRetry,
            "the recorded failure is never reset by a later closure");
    }

    /**
     * The real public event wait keeps its own interruption and failure, and the
     * still-interrupted later cleanup removes the owned observer honestly.
     */
    private static void a5NativeEventWaitInterrupt(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        Thread.currentThread().interrupt();
        Throwable thrown = null;
        boolean flagAfterWait;
        boolean captureFailedAfterWait;
        int attemptsAfterWait;
        int nativeAfterWait;
        boolean observingAfterWait;
        try {
            GuardedReaderApplication.endSaveObservation(2000);
        } catch (Throwable error) {
            thrown = error;
        }
        flagAfterWait = Thread.currentThread().isInterrupted();
        captureFailedAfterWait = GuardedReaderApplication.captureFailed();
        attemptsAfterWait = a5NativeObserverAttempts(observable);
        nativeAfterWait = a5NativeObserverCount(observable);
        observingAfterWait =
            GuardedReaderApplication.captureReceipt().optBoolean("observing");
        // The observer is still owned, so the real event can still be delivered.
        Thread.interrupted();
        deliver("http://book/1", "http://book/1/c1");
        // The later cleanup starts from the same interrupted caller state.
        Thread.currentThread().interrupt();
        JSONObject release = GuardedReaderApplication.releaseProcessResources();
        boolean flagAfterCleanup = Thread.currentThread().isInterrupted();
        int attemptsAfterCleanup = a5NativeObserverAttempts(observable);
        int effectsAfterCleanup = a5NativeObserverEffects(observable);
        int nativeAfterCleanup = a5NativeObserverCount(observable);
        JSONObject repeat = null;
        Throwable repeatError = null;
        try {
            repeat = GuardedReaderApplication.endSaveObservation(0);
        } catch (Throwable error) {
            repeatError = error;
        }
        Thread.interrupted();
        result.put("thrown", thrown == null ? "none" : thrown.getClass().getName())
            .put("chain", thrown == null ? "none" : FieldOracleFreeChain.describe(thrown))
            .put("flagAfterWait", flagAfterWait)
            .put("captureFailedAfterWait", captureFailedAfterWait)
            .put("attemptsAfterWait", attemptsAfterWait)
            .put("nativeAfterWait", nativeAfterWait)
            .put("observingAfterWait", observingAfterWait)
            .put("releaseClosed", release.optBoolean("closed"))
            .put("flagAfterCleanup", flagAfterCleanup)
            .put("attemptsAfterCleanup", attemptsAfterCleanup)
            .put("effectsAfterCleanup", effectsAfterCleanup)
            .put("nativeAfterCleanup", nativeAfterCleanup)
            .put("repeat", repeat)
            .put("repeatError", repeatError == null ? "none"
                : FieldOracleFreeChain.describe(repeatError))
            .put("captureFailed", GuardedReaderApplication.captureFailed());
        require(thrown instanceof InterruptedException,
            "the real wait surfaces its own interruption");
        require(flagAfterWait, "the original interrupt flag is preserved");
        require(captureFailedAfterWait, "the interrupted wait fails the capture");
        require(attemptsAfterWait == 0,
            "no fake removal acknowledgement is invented by the interruption");
        require(nativeAfterWait == 1 && observingAfterWait,
            "the observer stays owned after the interrupted wait");
        require(release.optBoolean("closed"),
            "the still-interrupted later cleanup closes honestly");
        require(flagAfterCleanup, "the entry interrupt is restored after cleanup");
        require(attemptsAfterCleanup == 1 && effectsAfterCleanup == 1,
            "the real cleanup reached and acknowledged the native removal");
        require(nativeAfterCleanup == 0, "the observer really went away");
        require(repeatError == null, "the repeat close does not wait or throw");
        require(repeat.optBoolean("alreadyClosed") && repeat.optBoolean("removed"),
            "the real close proof stands");
        require(repeat.optInt("events") == 1 && !repeat.optBoolean("failed"),
            "the original event validity is preserved");
        require(GuardedReaderApplication.captureFailed(),
            "the capture failure stays sticky");
    }

    // --- A5 repair: stale close, isolated interruptions, late error, errors ---

    /**
     * A delayed end for observation A must never remove or validate B. The
     * first A close really acknowledges; B is begun while the older A post is
     * held before its actual enqueue; the stale A post is then released and must
     * refuse without touching B's tuple or terminal. B still receives its own
     * typed event on MAIN and closes with B facts.
     */
    private static void a5RepairStaleObservationClose(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/A", "http://book/A/c1");
        deliver("http://book/A", "http://book/A/c1");
        java.util.concurrent.CountDownLatch[] nativeHold =
            a5NativeHold(observable, "removeEntered", "removeHeld");
        final JSONObject[] answers = {null, null};
        final Throwable[] errors = {null, null};
        Thread first = new Thread(() -> {
            try {
                answers[0] = GuardedReaderApplication.endSaveObservation(0);
            } catch (Throwable error) {
                errors[0] = error;
            }
        }, "a5-repair-first-close-A");
        first.start();
        boolean nativeEntered;
        boolean postEnteredOk;
        boolean firstJoined;
        boolean staleJoined;
        boolean idle;
        JSONObject beforeB;
        JSONObject afterStale;
        JSONObject staleAnswer;
        JSONObject second;
        JSONObject closure;
        int attemptsAfterStale;
        int effectsAfterStale;
        int nativeAfterStale;
        int attemptsAfterB;
        int effectsAfterB;
        int nativeAfterB;
        java.util.concurrent.CountDownLatch postEntered =
            new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.CountDownLatch postHeld =
            new java.util.concurrent.CountDownLatch(1);
        Thread stale = null;
        try {
            nativeEntered = nativeHold[0].await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            // The one-shot actual Handler.post entry hold: the older A close has
            // entered the external post but has not been enqueued yet.
            android.os.Handler.postEntered = postEntered;
            android.os.Handler.postHeld = postHeld;
            stale = new Thread(() -> {
                try {
                    answers[1] = GuardedReaderApplication.endSaveObservation(0);
                } catch (Throwable error) {
                    errors[1] = error;
                }
            }, "a5-repair-stale-close-A");
            stale.start();
            postEnteredOk = postEntered.await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            nativeHold[1].countDown();
            firstJoined = a5JoinBounded(first, 10000);
            // A is genuinely closed; B begins normally while the older A post is
            // still held before the queue.
            GuardedReaderApplication.beginSaveObservation("http://book/B", "http://book/B/c1");
            beforeB = GuardedReaderApplication.captureReceipt();
            postHeld.countDown();
            staleJoined = a5JoinBounded(stale, 10000);
            idle = android.os.Handler.awaitIdle(10000);
            afterStale = GuardedReaderApplication.captureReceipt();
            staleAnswer = answers[1];
            attemptsAfterStale = a5NativeObserverAttempts(observable);
            effectsAfterStale = a5NativeObserverEffects(observable);
            nativeAfterStale = a5NativeObserverCount(observable);
            // B receives its OWN typed event on MAIN and closes with B facts.
            deliver("http://book/B", "http://book/B/c1");
            second = GuardedReaderApplication.endSaveObservation(0);
            attemptsAfterB = a5NativeObserverAttempts(observable);
            effectsAfterB = a5NativeObserverEffects(observable);
            nativeAfterB = a5NativeObserverCount(observable);
            closure = GuardedReaderApplication.releaseProcessResources();
        } finally {
            nativeHold[1].countDown();
            a5NativeClearHold(observable, "removeEntered", "removeHeld");
            android.os.Handler.postEntered = null;
            android.os.Handler.postHeld = null;
            postHeld.countDown();
            first.join(40000);
            if (stale != null) stale.join(40000);
            android.os.Handler.awaitIdle(10000);
        }
        result.put("nativeEntered", nativeEntered).put("postEntered", postEnteredOk)
            .put("firstJoined", firstJoined).put("staleJoined", staleJoined)
            .put("idle", idle)
            .put("firstError", errors[0] == null ? "none"
                : FieldOracleFreeChain.describe(errors[0]))
            .put("staleError", errors[1] == null ? "none"
                : FieldOracleFreeChain.describe(errors[1]))
            .put("firstA", answers[0]).put("staleA", staleAnswer)
            .put("beforeB", beforeB).put("afterStaleA", afterStale)
            .put("attemptsAfterStale", attemptsAfterStale)
            .put("effectsAfterStale", effectsAfterStale)
            .put("nativeAfterStale", nativeAfterStale)
            .put("secondB", second)
            .put("attemptsAfterB", attemptsAfterB)
            .put("effectsAfterB", effectsAfterB)
            .put("nativeAfterB", nativeAfterB)
            .put("closure", closure)
            .put("captureFailed", GuardedReaderApplication.captureFailed());
        require(nativeEntered, "the first A removal was genuinely inside Native");
        require(postEnteredOk, "the stale A close was held inside the actual post");
        require(firstJoined, "the first A close terminated");
        require(staleJoined, "the stale A close terminated");
        require(idle, "the actual MAIN work finished");
        require(errors[0] == null, "the first A close did not throw");
        require(errors[1] == null, "the stale A close was refused, not thrown");
        require(answers[0] != null && answers[0].optInt("events") == 1
            && !answers[0].optBoolean("failed")
            && answers[0].getJSONObject("removal").optBoolean("removed"),
            "the first A close is a genuine valid acknowledgement");
        require(beforeB.optBoolean("observing") && beforeB.optInt("saveEvents") == 0
            && !beforeB.optBoolean("captureFailed"),
            "B is genuinely observed with no own event before the stale post");
        require(staleAnswer != null && staleAnswer.optBoolean("alreadyClosed")
            && !staleAnswer.optBoolean("removed")
            && "stale-observation".equals(staleAnswer.optString("reason")),
            "the stale A close is refused without inventing a removal");
        require(afterStale.optBoolean("observing") && afterStale.optInt("saveEvents") == 0
            && !afterStale.optBoolean("captureFailed"),
            "the stale A close did not touch B's observation or invent a B event");
        require(attemptsAfterStale == 1 && effectsAfterStale == 1 && nativeAfterStale == 1,
            "the stale A close made no native removal against B");
        require(second.optInt("events") == 1 && !second.optBoolean("failed")
            && second.getJSONObject("removal").optBoolean("removed"),
            "B closes with its own genuine valid facts");
        require("http://book/B".equals(second.getJSONObject("lastEvent").optString("bookUrl")),
            "B's terminal carries B's own event, never A's");
        require(attemptsAfterB == 2 && effectsAfterB == 2 && nativeAfterB == 0,
            "B's close is the second real attempt and effect");
        require(closure.optBoolean("closed"), "the later real release closes");
        require(!GuardedReaderApplication.captureFailed(),
            "the refused stale close does not fail the healthy capture");
    }

    /**
     * A clean entry-only interruption with all three real resource domains and
     * a valid typed event: the incoming flag is consumed for best effort and
     * restored, but it neither records nor clears a healthy capture failure.
     */
    private static void a5RepairEntryOnlyInterrupt(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        JSONObject prestate = GuardedReaderApplication.captureReceipt();
        final JSONObject[] receipt = {null};
        final Throwable[] error = {null};
        final boolean[] flagAfter = {false};
        Thread release = new Thread(() -> {
            Thread.currentThread().interrupt();
            try {
                receipt[0] = GuardedReaderApplication.releaseProcessResources();
                flagAfter[0] = Thread.currentThread().isInterrupted();
            } catch (Throwable thrown) {
                error[0] = thrown;
            }
        }, "a5-repair-entry-only-interrupt");
        release.start();
        boolean joined = a5JoinBounded(release, 30000);
        JSONObject releaseReceipt = receipt[0];
        JSONObject after = GuardedReaderApplication.captureReceipt();
        int attempts = a5NativeObserverAttempts(observable);
        int effects = a5NativeObserverEffects(observable);
        int nativeObservers = a5NativeObserverCount(observable);
        result.put("preEvents", prestate.optInt("saveEvents"))
            .put("preCaptureFailed", prestate.optBoolean("captureFailed"))
            .put("joined", joined)
            .put("error", error[0] == null ? "none"
                : FieldOracleFreeChain.describe(error[0]))
            .put("release", releaseReceipt).put("flagAfter", flagAfter[0])
            .put("attempts", attempts).put("effects", effects)
            .put("nativeObservers", nativeObservers)
            .put("nativeReceivers", app.nativeReceivers.size())
            .put("nativeCallbacks", app.nativeCallbacks.size())
            .put("captureFailedAfter", after.optBoolean("captureFailed"))
            .put("failures", after.getJSONArray("failures").toString());
        require(prestate.optInt("saveEvents") == 1
            && !prestate.optBoolean("captureFailed"),
            "the entry-only schedule starts from a healthy known capture");
        require(joined, "the entry-interrupted cleanup terminated");
        require(error[0] == null, "the entry-only cleanup itself did not throw");
        require(releaseReceipt != null && releaseReceipt.optBoolean("closed"),
            "a clean entry-only interruption still closes all three domains");
        require(flagAfter[0], "the incoming interrupt flag is restored after cleanup");
        require(!GuardedReaderApplication.captureFailed(),
            "an incoming flag alone does not fail a healthy capture");
        require(after.getJSONArray("failures").length() == 0,
            "an incoming flag alone records no failure");
        require(attempts == 1 && effects == 1 && nativeObservers == 0,
            "the observer is removed by one real attempt and effect");
        require(app.nativeReceivers.isEmpty() && app.nativeCallbacks.isEmpty(),
            "the receiver and lifecycle domains are genuinely empty");
        JSONObject observerClose = releaseReceipt.optJSONObject("observerClose");
        JSONObject removal = observerClose == null ? null
            : observerClose.optJSONObject("removal");
        require(removal != null && removal.optBoolean("removed"),
            "the observer close carries its genuine removal acknowledgement");
    }

    /**
     * An initially-clear-flag interruption during cleanup stays visible: the
     * observer removal is uncertain, the later domains still clean, the late
     * ACK finalizes the valid terminal, and the real retry closes.
     */
    private static void a5RepairMidOnlyInterrupt(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(observable, "removeEntered", "removeHeld");
        final JSONObject[] receipt = {null};
        final Throwable[] error = {null};
        final boolean[] flagAfter = {false};
        Thread release = new Thread(() -> {
            try {
                receipt[0] = GuardedReaderApplication.releaseProcessResources();
                flagAfter[0] = Thread.currentThread().isInterrupted();
            } catch (Throwable thrown) {
                error[0] = thrown;
            }
        }, "a5-repair-mid-only-interrupt");
        release.start();
        boolean entered;
        boolean joined;
        JSONObject releaseReceipt;
        int attemptsDuring;
        int effectsDuring;
        int nativeReceiversDuring;
        int nativeCallbacksDuring;
        boolean idle;
        int attemptsAfter;
        int effectsAfter;
        int nativeAfter;
        JSONObject repeat;
        JSONObject retry;
        try {
            entered = hold[0].await(10000, java.util.concurrent.TimeUnit.MILLISECONDS);
            // The flag is initially clear; the interrupt arrives during cleanup.
            release.interrupt();
            joined = a5JoinBounded(release, 20000);
            releaseReceipt = receipt[0];
            attemptsDuring = a5NativeObserverAttempts(observable);
            effectsDuring = a5NativeObserverEffects(observable);
            nativeReceiversDuring = app.nativeReceivers.size();
            nativeCallbacksDuring = app.nativeCallbacks.size();
            hold[1].countDown();
            a5NativeClearHold(observable, "removeEntered", "removeHeld");
            idle = android.os.Handler.awaitIdle(10000);
            attemptsAfter = a5NativeObserverAttempts(observable);
            effectsAfter = a5NativeObserverEffects(observable);
            nativeAfter = a5NativeObserverCount(observable);
            repeat = GuardedReaderApplication.endSaveObservation(0);
            retry = GuardedReaderApplication.releaseProcessResources();
        } finally {
            hold[1].countDown();
            a5NativeClearHold(observable, "removeEntered", "removeHeld");
            release.join(40000);
            android.os.Handler.awaitIdle(10000);
        }
        String removalFailures = releaseReceipt == null ? ""
            : releaseReceipt.optJSONArray("removalFailures").toString();
        String captureFailures = GuardedReaderApplication.captureReceipt()
            .getJSONArray("failures").toString();
        result.put("entered", entered).put("joined", joined)
            .put("error", error[0] == null ? "none"
                : FieldOracleFreeChain.describe(error[0]))
            .put("release", releaseReceipt).put("flagAfter", flagAfter[0])
            .put("attemptsDuring", attemptsDuring)
            .put("effectsDuring", effectsDuring)
            .put("nativeReceiversDuring", nativeReceiversDuring)
            .put("nativeCallbacksDuring", nativeCallbacksDuring)
            .put("idle", idle).put("attemptsAfter", attemptsAfter)
            .put("effectsAfter", effectsAfter).put("nativeAfter", nativeAfter)
            .put("repeat", repeat).put("retryClosed", retry.optBoolean("closed"))
            .put("removalFailures", removalFailures)
            .put("captureFailures", captureFailures)
            .put("captureFailed", GuardedReaderApplication.captureFailed());
        require(entered, "the observer removal was genuinely held inside Native");
        require(joined, "the mid-cleanup-interrupted cleanup terminated");
        require(error[0] == null, "the cleanup records the interruption, it does not throw");
        require(releaseReceipt != null && !releaseReceipt.optBoolean("closed"),
            "a mid-cleanup interruption is not reported as closure");
        require(removalFailures.contains("InterruptedException"),
            "the observer removal records the actual mid-cleanup interruption");
        require(captureFailures.contains("interrupted waiting for main-thread work"),
            "the mid-cleanup interruption is recorded as a capture failure");
        require(GuardedReaderApplication.captureFailed(),
            "the mid-cleanup interruption fails the capture");
        require(flagAfter[0], "the mid-cleanup interrupt remains visible");
        require(attemptsDuring == 1 && effectsDuring == 0,
            "the held removal made one attempt and no effect");
        require(nativeReceiversDuring == 0 && nativeCallbacksDuring == 0,
            "the later receiver and lifecycle domains still cleaned");
        require(idle, "the real removal body finished on MAIN");
        require(attemptsAfter == 1 && effectsAfter == 1 && nativeAfter == 0,
            "the late ACK is exactly one attempt and one effect");
        require(repeat.optBoolean("alreadyClosed") && repeat.optBoolean("removed")
            && repeat.optInt("events") == 1 && !repeat.optBoolean("failed"),
            "the late ACK finalizes the valid terminal");
        require(retry.optBoolean("closed"), "the later real retry closes");
    }

    /**
     * An after-effect observer throw after the waiter departed keeps the full
     * original graph and the exact uncertainty even though the native observer
     * registry is already empty; only the genuine second absent-return ACK is a
     * success.
     */
    private static void a5RepairObserverAfterEffectLateError(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        Object observable = liveObservableForTest();
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        java.util.concurrent.CountDownLatch[] hold =
            a5NativeHold(observable, "removeAfterEntered", "removeAfterHeld");
        final Throwable[] callerError = {null};
        Thread caller = new Thread(() -> {
            try {
                GuardedReaderApplication.endSaveObservation(0);
            } catch (Throwable error) {
                callerError[0] = error;
            }
        }, "a5-repair-observer-after-effect-late-error");
        caller.start();
        boolean entered;
        boolean joined;
        int attemptsAtHold;
        int effectsAtHold;
        int nativeAtHold;
        boolean idle;
        String failures;
        JSONObject afterError;
        int attemptsAfterError;
        int effectsAfterError;
        int nativeAfterError;
        JSONObject retry;
        int attemptsAfterRetry;
        int effectsAfterRetry;
        int nativeAfterRetry;
        JSONObject release;
        try {
            entered = hold[0].await(5000, java.util.concurrent.TimeUnit.MILLISECONDS);
            attemptsAtHold = a5NativeObserverAttempts(observable);
            effectsAtHold = a5NativeObserverEffects(observable);
            nativeAtHold = a5NativeObserverCount(observable);
            // The waiter departs before the after-effect throw.
            caller.interrupt();
            joined = a5JoinBounded(caller, 10000);
            RuntimeException original = new IllegalStateException("A5_AFTER_EFFECT_ERROR",
                new IllegalArgumentException("A5_AFTER_EFFECT_NESTED"));
            original.addSuppressed(new IllegalStateException("A5_AFTER_EFFECT_SUPPRESSED"));
            setObservableField(observable, "observerRemoveAfterEffect", original);
            hold[1].countDown();
            a5NativeClearHold(observable, "removeAfterEntered", "removeAfterHeld");
            idle = android.os.Handler.awaitIdle(10000);
            failures = GuardedReaderApplication.captureReceipt()
                .getJSONArray("failures").toString();
            afterError = GuardedReaderApplication.captureReceipt();
            attemptsAfterError = a5NativeObserverAttempts(observable);
            effectsAfterError = a5NativeObserverEffects(observable);
            nativeAfterError = a5NativeObserverCount(observable);
            setObservableField(observable, "observerRemoveAfterEffect", null);
            retry = GuardedReaderApplication.endSaveObservation(0);
            attemptsAfterRetry = a5NativeObserverAttempts(observable);
            effectsAfterRetry = a5NativeObserverEffects(observable);
            nativeAfterRetry = a5NativeObserverCount(observable);
            release = GuardedReaderApplication.releaseProcessResources();
        } finally {
            hold[1].countDown();
            a5NativeClearHold(observable, "removeAfterEntered", "removeAfterHeld");
            setObservableField(observable, "observerRemoveAfterEffect", null);
            caller.join(40000);
            android.os.Handler.awaitIdle(10000);
        }
        result.put("entered", entered).put("joined", joined)
            .put("callerError", callerError[0] == null ? "none"
                : FieldOracleFreeChain.describe(callerError[0]))
            .put("attemptsAtHold", attemptsAtHold)
            .put("effectsAtHold", effectsAtHold).put("nativeAtHold", nativeAtHold)
            .put("idle", idle).put("failures", failures)
            .put("observingAfterError", afterError.optBoolean("observing"))
            .put("observerClosedAfterError", afterError.optBoolean("observerClosed"))
            .put("attemptsAfterError", attemptsAfterError)
            .put("effectsAfterError", effectsAfterError)
            .put("nativeAfterError", nativeAfterError)
            .put("retry", retry).put("attemptsAfterRetry", attemptsAfterRetry)
            .put("effectsAfterRetry", effectsAfterRetry)
            .put("nativeAfterRetry", nativeAfterRetry)
            .put("releaseClosed", release.optBoolean("closed"));
        require(entered, "the real removal body was genuinely held after its effect");
        require(attemptsAtHold == 1 && effectsAtHold == 1 && nativeAtHold == 0,
            "the held removal already effected once and the native observer is gone");
        require(joined, "the interrupted waiter exited before the after-effect throw");
        require(callerError[0] instanceof InterruptedException,
            "the departed waiter keeps its own interruption");
        require(failures.contains("A5_AFTER_EFFECT_ERROR")
            && failures.contains("A5_AFTER_EFFECT_NESTED")
            && failures.contains("A5_AFTER_EFFECT_SUPPRESSED"),
            "the late after-effect primary, nested and suppressed graph is retained");
        require(afterError.optBoolean("observing")
            && !afterError.optBoolean("observerClosed"),
            "the failed after-effect removal keeps the exact uncertainty and no false closure");
        require(attemptsAfterError == 1 && effectsAfterError == 1 && nativeAfterError == 0,
            "the uncertainty is retained even though the native registry is empty");
        require(retry.getJSONObject("removal").optBoolean("removed"),
            "the retry returns a genuine absent-return ACK");
        require(retry.optInt("events") == 1 && !retry.optBoolean("failed"),
            "the retry carries the correct case proof");
        require(attemptsAfterRetry == 2 && effectsAfterRetry == 1 && nativeAfterRetry == 0,
            "the ACK is a second real attempt with no second effect");
        require(release.optBoolean("closed"), "the later real release closes");
    }

    /**
     * Bounded simultaneous public error producers: every required record is
     * retained, and a concurrent receipt snapshot never observes a torn array.
     */
    private static void a5RepairConcurrentErrorRetention(JSONObject result) throws Exception {
        GuardedReaderApplication app = armedApp();
        int producers = 12;
        int perProducer = 25;
        int total = producers * perProducer;
        final java.util.concurrent.CountDownLatch start =
            new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.atomic.AtomicBoolean stop =
            new java.util.concurrent.atomic.AtomicBoolean();
        final java.util.concurrent.atomic.AtomicReference<Throwable> readerError =
            new java.util.concurrent.atomic.AtomicReference<>();
        Thread reader = new Thread(() -> {
            try {
                start.await();
                while (!stop.get()) {
                    JSONObject snapshot = GuardedReaderApplication.captureReceipt();
                    int failures = snapshot.getJSONArray("failures").length();
                    if (failures < 0 || failures > total) {
                        throw new AssertionError("torn failure snapshot: " + failures);
                    }
                    Thread.yield();
                }
            } catch (Throwable error) {
                readerError.set(error);
            }
        }, "a5-repair-error-reader");
        reader.start();
        Thread[] workers = new Thread[producers];
        final java.util.concurrent.atomic.AtomicReference<Throwable> producerError =
            new java.util.concurrent.atomic.AtomicReference<>();
        for (int i = 0; i < producers; i++) {
            final boolean receiver = i % 2 == 0;
            workers[i] = new Thread(() -> {
                try {
                    start.await();
                    for (int n = 0; n < perProducer; n++) {
                        try {
                            if (receiver) {
                                app.unregisterReceiver(new ForeignReceiver());
                            } else {
                                app.unregisterActivityLifecycleCallbacks(new ForeignLifecycle());
                            }
                        } catch (SecurityException expected) {
                            // The public refusal is the required error record.
                        }
                    }
                } catch (Throwable error) {
                    producerError.compareAndSet(null, error);
                }
            }, "a5-repair-error-producer-" + i);
            workers[i].start();
        }
        start.countDown();
        for (Thread worker : workers) worker.join(30000);
        stop.set(true);
        reader.join(30000);
        JSONObject receipt = GuardedReaderApplication.captureReceipt();
        org.json.JSONArray failures = receipt.getJSONArray("failures");
        int receiverFailures = 0;
        int lifecycleFailures = 0;
        for (int i = 0; i < failures.length(); i++) {
            String failure = failures.getString(i);
            if (failure.startsWith("unregister of a receiver the guard does not own")) {
                receiverFailures++;
            } else if (failure.startsWith(
                    "unregister of a lifecycle callback the guard does not own")) {
                lifecycleFailures++;
            }
        }
        result.put("total", total).put("retained", failures.length())
            .put("receiverFailures", receiverFailures)
            .put("lifecycleFailures", lifecycleFailures)
            .put("foreignUnregistrations", receipt.optInt("foreignUnregistrations"))
            .put("readerError", readerError.get() == null ? "none"
                : FieldOracleFreeChain.describe(readerError.get()))
            .put("producerError", producerError.get() == null ? "none"
                : FieldOracleFreeChain.describe(producerError.get()))
            .put("captureFailed", receipt.optBoolean("captureFailed"));
        for (Thread worker : workers) {
            require(!worker.isAlive(), "every public error producer terminated");
        }
        require(!reader.isAlive(), "the concurrent receipt reader terminated");
        require(producerError.get() == null,
            "no producer failed outside the intended public refusal");
        require(readerError.get() == null,
            "no concurrent receipt snapshot observed a torn failure array");
        require(failures.length() == total,
            "every required public error record is retained");
        require(receiverFailures == total / 2 && lifecycleFailures == total / 2,
            "both required error families are fully retained");
        require(receipt.optInt("foreignUnregistrations") == total,
            "every refused unregistration is counted");
        require(receipt.optBoolean("captureFailed"),
            "the public errors fail the capture");
    }

    /**
     * The removal reservation survives the original error rendering: while the
     * first caller is inside the actual Throwable rendering boundary, two
     * competing final cleanups must refuse completion and never clear this
     * caller's reservation; then the recorded failure and the genuine retry ACK
     * complete the lifetime.
     */
    private static void a5RepairRemovalErrorBookkeeping(JSONObject result, boolean lifecycle,
            boolean publicCaller) throws Exception {
        GuardedReaderApplication app = armedApp();
        final com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newReceiver();
        app.registerReceiver(receiver, new IntentFilter(ACTION), 2);
        final Object callback = approvedCallback();
        app.registerActivityLifecycleCallbacks(
            (Application.ActivityLifecycleCallbacks) callback);
        GuardedReaderApplication.beginSaveObservation("http://book/1", "http://book/1/c1");
        deliver("http://book/1", "http://book/1/c1");
        final java.util.concurrent.CountDownLatch renderingEntered =
            new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch renderingHeld =
            new java.util.concurrent.CountDownLatch(1);
        // The actual external error-rendering boundary: the guard's real
        // stackTraceOf(error) calls this virtual method from its catch, after the
        // native failure and before it records or publishes the failure.
        RuntimeException original = new IllegalStateException("A5_REPAIR_REMOVAL_PRIMARY",
            new IllegalArgumentException("A5_REPAIR_REMOVAL_NESTED")) {
            @Override public void printStackTrace(java.io.PrintWriter writer) {
                renderingEntered.countDown();
                try {
                    if (!renderingHeld.await(20, java.util.concurrent.TimeUnit.SECONDS)) {
                        throw new IllegalStateException(
                            "the controlled error rendering was not released in time");
                    }
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
                super.printStackTrace(writer);
            }
        };
        original.addSuppressed(new IllegalStateException("A5_REPAIR_REMOVAL_SUPPRESSED"));
        if (lifecycle) {
            app.lifecycleUnregisterAfterEffect = original;
        } else {
            app.receiverUnregisterBeforeEffect = original;
        }
        final JSONObject[] firstReceipt = {null};
        final Throwable[] firstError = {null};
        Thread first = new Thread(() -> {
            try {
                if (publicCaller) {
                    if (lifecycle) {
                        app.unregisterActivityLifecycleCallbacks(
                            (Application.ActivityLifecycleCallbacks) callback);
                    } else {
                        app.unregisterReceiver(receiver);
                    }
                } else {
                    firstReceipt[0] = GuardedReaderApplication.releaseProcessResources();
                }
            } catch (Throwable error) {
                firstError[0] = error;
            }
        }, "a5-repair-removal-error-" + (lifecycle ? "lifecycle" : "receiver") + "-"
            + (publicCaller ? "public" : "release"));
        first.start();
        boolean entered = false;
        JSONObject firstCompeting = null;
        JSONObject secondCompeting = null;
        int attemptsWhileHeld = -1;
        int effectsWhileHeld = -1;
        int nativeWhileHeld = -1;
        boolean unrelatedEmpty = false;
        boolean observerClosed = false;
        boolean firstJoined = false;
        boolean idle = false;
        try {
            entered = renderingEntered.await(10000, java.util.concurrent.TimeUnit.MILLISECONDS);
            // The original error has already happened; only its graph is held.
            if (lifecycle) {
                app.lifecycleUnregisterAfterEffect = null;
            } else {
                app.receiverUnregisterBeforeEffect = null;
            }
            firstCompeting = GuardedReaderApplication.releaseProcessResources();
            secondCompeting = GuardedReaderApplication.releaseProcessResources();
            attemptsWhileHeld = lifecycle ? app.lifecycleUnregisterAttempts
                : app.receiverUnregisterAttempts;
            effectsWhileHeld = lifecycle ? app.lifecycleUnregisterEffects
                : app.receiverUnregisterEffects;
            nativeWhileHeld = lifecycle ? app.nativeCallbacks.size()
                : app.nativeReceivers.size();
            unrelatedEmpty = lifecycle ? app.nativeReceivers.isEmpty()
                : app.nativeCallbacks.isEmpty();
            observerClosed = !GuardedReaderApplication.captureReceipt().optBoolean("observing");
        } finally {
            renderingHeld.countDown();
            first.join(40000);
            firstJoined = !first.isAlive();
            if (lifecycle) {
                app.lifecycleUnregisterAfterEffect = null;
            } else {
                app.receiverUnregisterBeforeEffect = null;
            }
            idle = android.os.Handler.awaitIdle(10000);
        }
        JSONObject capture = GuardedReaderApplication.captureReceipt();
        org.json.JSONArray retained = capture.getJSONArray("failures");
        int primaries = 0;
        int nesteds = 0;
        int suppresseds = 0;
        for (int i = 0; i < retained.length(); i++) {
            String entry = retained.getString(i);
            if (entry.contains("A5_REPAIR_REMOVAL_PRIMARY")) primaries++;
            if (entry.contains("A5_REPAIR_REMOVAL_NESTED")) nesteds++;
            if (entry.contains("A5_REPAIR_REMOVAL_SUPPRESSED")) suppresseds++;
        }
        String firstChain = firstError[0] == null ? "none"
            : FieldOracleFreeChain.describe(firstError[0]);
        result.put("lifecycle", lifecycle).put("publicCaller", publicCaller)
            .put("entered", entered)
            .put("firstCompeting", firstCompeting).put("secondCompeting", secondCompeting)
            .put("attemptsWhileHeld", attemptsWhileHeld)
            .put("effectsWhileHeld", effectsWhileHeld)
            .put("nativeWhileHeld", nativeWhileHeld)
            .put("unrelatedEmpty", unrelatedEmpty)
            .put("observerClosed", observerClosed)
            .put("firstJoined", firstJoined).put("idle", idle)
            .put("firstError", firstChain).put("firstReceipt", firstReceipt[0])
            .put("retainedPrimaries", primaries).put("retainedNesteds", nesteds)
            .put("retainedSuppresseds", suppresseds)
            .put("captureFailed", capture.optBoolean("captureFailed"));
        require(entered, "the first caller reached the actual error-rendering boundary");
        require(firstCompeting != null && !firstCompeting.optBoolean("closed"),
            "the first competing cleanup must refuse completion while the error is unpublished: "
                + firstCompeting);
        require(secondCompeting != null && !secondCompeting.optBoolean("closed"),
            "the second competing cleanup must refuse completion while the error is unpublished: "
                + secondCompeting);
        require(attemptsWhileHeld == 1,
            "the competing cleanups never duplicate the target native removal call");
        require(effectsWhileHeld == (lifecycle ? 1 : 0),
            "the held removal keeps its exact single effect state");
        require(nativeWhileHeld == (lifecycle ? 0 : 1),
            "the held removal keeps its exact native registry state");
        require(unrelatedEmpty, "the unrelated owned domain still cleaned normally");
        require(observerClosed, "the observer domain still closed normally");
        require(firstJoined, "the first caller terminated after the rendering was released");
        require(idle, "the actual MAIN work finished");
        require(primaries == 1 && nesteds == 1 && suppresseds == 1,
            "exactly one complete original primary, nested and suppressed graph is retained");
        require(capture.optBoolean("captureFailed"),
            "the original removal failure is sticky");
        if (publicCaller) {
            require(firstError[0] instanceof SecurityException,
                "the public removal propagates its documented refusal");
            require(FieldOracleFreeChain.hasCause(firstError[0], original),
                "the propagated refusal keeps the original error as its cause");
            require(firstError[0].getMessage().contains("A5_REPAIR_REMOVAL_PRIMARY"),
                "the propagated refusal names the original error");
        } else {
            require(firstError[0] == null, "the final release records, it does not throw");
            require(firstReceipt[0] != null && !firstReceipt[0].optBoolean("closed"),
                "the first final receipt is not a false closure");
            require(firstReceipt[0].getJSONArray("removalFailures").toString()
                .contains("A5_REPAIR_REMOVAL_PRIMARY"),
                "the first final receipt contains the complete original removal failure");
        }
        JSONObject retry = GuardedReaderApplication.releaseProcessResources();
        int attemptsAfterRetry = lifecycle ? app.lifecycleUnregisterAttempts
            : app.receiverUnregisterAttempts;
        int effectsAfterRetry = lifecycle ? app.lifecycleUnregisterEffects
            : app.receiverUnregisterEffects;
        int nativeAfterRetry = lifecycle ? app.nativeCallbacks.size()
            : app.nativeReceivers.size();
        result.put("retryClosed", retry.optBoolean("closed"))
            .put("attemptsAfterRetry", attemptsAfterRetry)
            .put("effectsAfterRetry", effectsAfterRetry)
            .put("nativeAfterRetry", nativeAfterRetry);
        require(retry.optBoolean("closed"), "the genuine final retry ACK closes");
        require(attemptsAfterRetry == 2,
            "the genuine retry is the second real target attempt");
        require(effectsAfterRetry == 1,
            "the target effected exactly once across the failed call and the ACK");
        require(nativeAfterRetry == 0, "the target native registry is empty");
    }

    /** Bounded join that surfaces the real liveness result. */
    private static boolean a5JoinBounded(Thread thread, long millis) throws Exception {
        thread.join(millis);
        return !thread.isAlive();
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
