package io.liber.oracle.nested;

import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import java.util.ArrayList;
import java.util.List;

/**
 * Actual behavioural controls for the capture guard.
 *
 * <p>This runs the real {@link GuardedReaderApplication} against bounded OS and
 * dependency boundary fakes on a plain JVM. It is host evidence for the guard's
 * ownership, refusal, observer and cleanup behaviour; it is not Android
 * execution evidence and does not exercise the reference APK.
 *
 * <p>Usage: {@code java io.liber.oracle.nested.GuardedReaderApplicationTest}
 * prints one line per control and a final {@code SUMMARY pass=<n> fail=<n>}.
 */
public final class GuardedReaderApplicationTest {
    private static final List<String> failures = new ArrayList<>();
    private static int passed;

    /** A stand-in for the reference Book payload the save event carries. */
    static final class FakeBook {
        private final String bookUrl;
        FakeBook(String bookUrl) { this.bookUrl = bookUrl; }
        public String getBookUrl() { return bookUrl; }
    }

    /** A stand-in for the reference BookChapter payload. */
    static final class FakeChapter {
        private final String url;
        FakeChapter(String url) { this.url = url; }
        public String getUrl() { return url; }
    }

    /** The exact receiver class name the guard accepts. */
    static com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver newLebReceiver() {
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver.delivered = 0;
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver.extrasRead = false;
        return new com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver();
    }

    /** A receiver the guard must refuse. */
    static final class ForeignReceiver extends BroadcastReceiver {
        @Override public void onReceive(Context context, Intent intent) {}
    }

    static com.jeremyliao.liveeventbus.utils.AppUtils.ActivityLifecycleImpl newLifecycle() {
        return new com.jeremyliao.liveeventbus.utils.AppUtils.ActivityLifecycleImpl();
    }

    static final class ForeignLifecycle implements Application.ActivityLifecycleCallbacks {
        @Override public void onActivityCreated(Object activity, android.os.Bundle state) {}
    }

    public static void main(String[] args) throws Exception {
        inactiveBehaviour();
        activityRefusals();
        exactRegistrationAccepted();
        wrongRegistrationsRefused();
        inboundIpcNeverDelivered();
        registrationFailureStaysVisible();
        unregistrationOwnership();
        releaseIsIdempotent();
        observerLifecycle();
        observerForeignAndDuplicateEvents();
        preferencePresenceRoundTrip();
        System.out.println("SUMMARY pass=" + passed + " fail=" + failures.size());
        for (String failure : failures) System.out.println("FAILURE " + failure);
        System.exit(failures.isEmpty() ? 0 : 1);
    }

    // --- controls ---------------------------------------------------------

    private static void inactiveBehaviour() {
        GuardedReaderApplication app = new GuardedReaderApplication();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newLebReceiver();
        IntentFilter filter = new IntentFilter(GuardedReaderApplication.LEB_IPC_ACTION);
        app.registerReceiver(receiver, filter, 2);
        check("inactive registration is not wrapped",
            app.lastReceiver == receiver && app.registered.size() == 1);
        check("inactive registration keeps the caller's flags", app.lastFlags == 2);
        app.unregisterReceiver(receiver);
        check("inactive unregistration passes through",
            app.unregistered.size() == 1 && app.unregistered.get(0).equals(receiver.getClass().getName()));
        check("inactive guard records nothing",
            !GuardedReaderApplication.isArmed());
    }

    private static void activityRefusals() {
        GuardedReaderApplication app = new GuardedReaderApplication();
        int before = GuardedReaderApplication.launchAttempts();
        boolean first = false;
        boolean second = false;
        try { app.startActivity(new Intent("x")); } catch (SecurityException expected) { first = true; }
        try { app.startActivity(new Intent("x"), new android.os.Bundle()); }
        catch (SecurityException expected) { second = true; }
        check("both activity launches are refused", first && second);
        check("activity refusals are counted",
            GuardedReaderApplication.launchAttempts() == before + 2);
    }

    private static void exactRegistrationAccepted() throws Exception {
        GuardedReaderApplication app = armedApplication();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newLebReceiver();
        IntentFilter filter = new IntentFilter(GuardedReaderApplication.LEB_IPC_ACTION);
        app.registerReceiver(receiver, filter, 2);
        check("the exact registration is wrapped",
            app.lastReceiver != null && app.lastReceiver != receiver);
        check("the exact registration keeps the caller's flags", app.lastFlags == 2);
        check("the exact registration is tracked only after the platform return",
            app.registered.size() == 1);
        com.jeremyliao.liveeventbus.utils.AppUtils.ActivityLifecycleImpl lifecycle = newLifecycle();
        app.registerActivityLifecycleCallbacks(lifecycle);
        check("the exact lifecycle callback is registered",
            app.lifecycleRegistered.size() == 1);
        GuardedReaderApplication.releaseProcessResources();
        GuardedReaderApplication.arm(null, null);
    }

    private static void wrongRegistrationsRefused() throws Exception {
        GuardedReaderApplication app = armedApplication();
        int before = app.registered.size();
        expectRefusal("a foreign receiver class is refused", () ->
            app.registerReceiver(new ForeignReceiver(),
                new IntentFilter(GuardedReaderApplication.LEB_IPC_ACTION), 2));
        expectRefusal("a foreign action is refused", () ->
            app.registerReceiver(newLebReceiver(), new IntentFilter("other.action"), 2));
        expectRefusal("the wrong flags are refused", () ->
            app.registerReceiver(newLebReceiver(),
                new IntentFilter(GuardedReaderApplication.LEB_IPC_ACTION), 4));
        expectRefusal("a filter with a category is refused", () -> {
            IntentFilter filter = new IntentFilter(GuardedReaderApplication.LEB_IPC_ACTION);
            filter.addCategory("c");
            app.registerReceiver(newLebReceiver(), filter, 2);
        });
        expectRefusal("a foreign lifecycle callback is refused", () ->
            app.registerActivityLifecycleCallbacks(new ForeignLifecycle()));
        check("no refused registration reached the platform", app.registered.size() == before);
        GuardedReaderApplication.releaseProcessResources();
        GuardedReaderApplication.arm(null, null);
    }

    private static void inboundIpcNeverDelivered() throws Exception {
        GuardedReaderApplication app = armedApplication();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newLebReceiver();
        app.registerReceiver(receiver, new IntentFilter(GuardedReaderApplication.LEB_IPC_ACTION), 2);
        BroadcastReceiver wrapper = app.lastReceiver;
        Intent inbound = new Intent(GuardedReaderApplication.LEB_IPC_ACTION);
        wrapper.onReceive(app, inbound);
        check("an inbound IPC attempt is never delivered to the native receiver",
            com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver.delivered == 0);
        check("an inbound IPC attempt never reads the native extras", !inbound.extrasRead);
        org.json.JSONObject receipt = GuardedReaderApplication.captureReceipt();
        check("an inbound IPC attempt is recorded as a failure",
            receipt.optInt("blockedDeliveries") == 1
                && receipt.getJSONArray("inboundAttempts").length() == 1);
        GuardedReaderApplication.releaseProcessResources();
        GuardedReaderApplication.arm(null, null);
    }

    private static void registrationFailureStaysVisible() throws Exception {
        GuardedReaderApplication app = armedApplication();
        app.registerFailure = new SecurityException("platform refused");
        expectRefusal("a platform registration failure is rethrown", () ->
            app.registerReceiver(newLebReceiver(),
                new IntentFilter(GuardedReaderApplication.LEB_IPC_ACTION), 2));
        org.json.JSONObject receipt = GuardedReaderApplication.captureReceipt();
        int successfulBefore = successfulRegistrations();
        check("a failed registration is not counted as successful",
            successfulRegistrations() == successfulBefore
                && receipt.getJSONArray("failures").length() >= 1);
        check("a failed registration is recorded",
            receipt.getJSONArray("failures").length() >= 1);
        app.registerFailure = null;
        app.registerReceiver(newLebReceiver(),
            new IntentFilter(GuardedReaderApplication.LEB_IPC_ACTION), 2);
        check("a later successful registration is counted",
            successfulRegistrations() == successfulBefore + 1);
        GuardedReaderApplication.releaseProcessResources();
        GuardedReaderApplication.arm(null, null);
    }

    private static void unregistrationOwnership() throws Exception {
        GuardedReaderApplication app = armedApplication();
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver receiver = newLebReceiver();
        app.registerReceiver(receiver, new IntentFilter(GuardedReaderApplication.LEB_IPC_ACTION), 2);
        BroadcastReceiver wrapper = app.lastReceiver;
        app.unregisterReceiver(receiver);
        check("the guard translates its own unregistration",
            app.unregistered.size() == 1
                && app.unregistered.get(0).equals(wrapper.getClass().getName()));
        app.unregisterReceiver(new ForeignReceiver());
        check("a foreign unregistration is recorded, not claimed",
            GuardedReaderApplication.captureReceipt().optInt("foreignUnregistrations") == 1);
        app.unregisterFailure = new RuntimeException("platform refused removal");
        com.jeremyliao.liveeventbus.ipc.receiver.LebIpcReceiver second = newLebReceiver();
        app.registerReceiver(second, new IntentFilter(GuardedReaderApplication.LEB_IPC_ACTION), 2);
        boolean threw = false;
        try { app.unregisterReceiver(second); } catch (RuntimeException expected) { threw = true; }
        check("a failed removal is visible", threw);
        app.unregisterFailure = null;
        GuardedReaderApplication.releaseProcessResources();
        GuardedReaderApplication.arm(null, null);
    }

    private static void releaseIsIdempotent() throws Exception {
        GuardedReaderApplication app = armedApplication();
        app.registerReceiver(newLebReceiver(),
            new IntentFilter(GuardedReaderApplication.LEB_IPC_ACTION), 2);
        app.registerActivityLifecycleCallbacks(newLifecycle());
        org.json.JSONObject first = GuardedReaderApplication.releaseProcessResources();
        check("the first release closes every owned resource",
            first.optBoolean("closed") && first.optInt("removedReceivers") == 1
                && first.optInt("removedLifecycleCallbacks") == 1);
        org.json.JSONObject second = GuardedReaderApplication.releaseProcessResources();
        check("a repeated release owns nothing and does not double-remove",
            second.optBoolean("closed") && second.optInt("ownedReceivers") == 0
                && app.unregistered.size() == 1);
        check("the owner is preserved for the lifetime",
            GuardedReaderApplication.captureReceipt().optString("ownerClass")
                .endsWith("GuardedReaderApplication"));
        GuardedReaderApplication.arm(null, null);
    }

    private static void observerLifecycle() throws Exception {
        GuardedReaderApplication app = armedApplication();
        resetObservableCounters();
        org.json.JSONObject begin = GuardedReaderApplication.beginSaveObservation(
            "http://book/1", "http://book/1/c1");
        check("the observer is registered through the public interface",
            begin.optBoolean("registered")
                && begin.optString("interface")
                    .equals(GuardedReaderApplication.OBSERVABLE_INTERFACE)
                && begin.optString("declaringClass")
                    .equals(GuardedReaderApplication.OBSERVABLE_INTERFACE));
        Object observable = liveObservable();
        deliver(observable, new FakeBook("http://book/1"), new FakeChapter("http://book/1/c1"));
        org.json.JSONObject end = GuardedReaderApplication.endSaveObservation(2000);
        check("the correlated event is counted", end.optInt("events") == 1);
        check("the observer removal is acknowledged",
            end.getJSONObject("removal").optBoolean("removed")
                && end.getJSONObject("removal").optString("declaringClass")
                    .equals(GuardedReaderApplication.OBSERVABLE_INTERFACE));
        check("the non-public implementation really removed the observer",
            removeCalls(observable) == 1);
        GuardedReaderApplication.releaseProcessResources();
        GuardedReaderApplication.arm(null, null);
    }

    private static void observerForeignAndDuplicateEvents() throws Exception {
        GuardedReaderApplication app = armedApplication();
        resetObservableCounters();
        GuardedReaderApplication.beginSaveObservation("http://book/2", "http://book/2/c1");
        Object observable = liveObservable();
        deliver(observable, new FakeBook("http://other"), new FakeChapter("http://other/c1"));
        deliver(observable, new FakeBook("http://book/2"), new FakeChapter("http://book/2/c1"));
        deliver(observable, new FakeBook("http://book/2"), new FakeChapter("http://book/2/c1"));
        org.json.JSONObject end = GuardedReaderApplication.endSaveObservation(2000);
        check("a foreign event is not counted as this case's",
            end.optInt("foreignEvents") == 1);
        check("a duplicate correlated event is counted", end.optInt("events") == 2);
        check("a duplicate event does not create a second observer",
            observeCalls(observable) == 1);
        GuardedReaderApplication.releaseProcessResources();
        GuardedReaderApplication.arm(null, null);
    }

    private static void preferencePresenceRoundTrip() {
        Context context = new Context();
        android.content.SharedPreferences preferences =
            context.getSharedPreferences("liber_fields_02_config", 0);
        check("an absent preference starts absent", !preferences.contains("tocCountWords"));
        preferences.edit().putBoolean("tocCountWords", true).commit();
        check("an applied preference is present", preferences.contains("tocCountWords"));
        preferences.edit().remove("tocCountWords").commit();
        check("a removed preference is absent again", !preferences.contains("tocCountWords"));
        android.content.SharedPreferences.Editor failing = preferences.edit();
        failing.commitResult = false;
        check("a refused commit reports false", !failing.putBoolean("tocCountWords", true).commit());
    }

    // --- helpers ----------------------------------------------------------

    private static GuardedReaderApplication armedApplication() throws Exception {
        GuardedReaderApplication app = new GuardedReaderApplication();
        GuardedReaderApplication.arm(app, GuardedReaderApplicationTest.class.getClassLoader());
        return app;
    }

    private static Object liveObservable() throws Exception {
        return Class.forName("com.jeremyliao.liveeventbus.LiveEventBus")
            .getMethod("get", String.class, Class.class)
            .invoke(null, GuardedReaderApplication.SAVE_CONTENT_TAG,
                Class.forName("kotlin.Pair"));
    }

    private static void deliver(Object observable, Object book, Object chapter) throws Exception {
        Object pair = Class.forName("kotlin.Pair").getConstructor(Object.class, Object.class)
            .newInstance(book, chapter);
        // The fixture's own delivery hook lives on the non-public fake; the
        // guard never needs this access, only the test's stimulus does.
        java.lang.reflect.Method deliver =
            observable.getClass().getDeclaredMethod("deliver", Object.class);
        deliver.setAccessible(true);
        deliver.invoke(observable, pair);
    }

    private static int successfulRegistrations() throws Exception {
        return GuardedReaderApplication.captureReceipt().optInt("successfulRegistrations");
    }

    private static void resetObservableCounters() throws Exception {
        Object observable = liveObservable();
        java.lang.reflect.Method reset =
            observable.getClass().getDeclaredMethod("resetCounters");
        reset.setAccessible(true);
        reset.invoke(observable);
    }

    private static int observeCalls(Object observable) throws Exception {
        java.lang.reflect.Field field = observable.getClass().getDeclaredField("observeCalls");
        field.setAccessible(true);
        return (Integer) field.get(observable);
    }

    private static int removeCalls(Object observable) throws Exception {
        java.lang.reflect.Field field = observable.getClass().getDeclaredField("removeCalls");
        field.setAccessible(true);
        return (Integer) field.get(observable);
    }

    private interface Refusal {
        void run() throws Exception;
    }

    private static void expectRefusal(String name, Refusal action) {
        try {
            action.run();
            failures.add(name + " (no refusal)");
        } catch (SecurityException expected) {
            passed++;
            System.out.println("PASS " + name);
        } catch (Exception other) {
            failures.add(name + " (" + other + ")");
        }
    }

    private static void check(String name, boolean condition) {
        if (condition) {
            passed++;
            System.out.println("PASS " + name);
        } else {
            failures.add(name);
            System.out.println("FAIL " + name);
        }
    }
}
