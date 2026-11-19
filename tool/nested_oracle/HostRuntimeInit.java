package io.liber.oracle.nested;

import android.content.ContextWrapper;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Map;
import java.util.TreeMap;

/**
 * Performs the one runtime initialization the selected reference needs before a
 * script runs, without starting the real {@code io.legado.app.App} lifecycle.
 *
 * <p>{@code App.initRhino()} is the only startup step the script engines depend
 * on: it calls {@code RhinoScriptEngine.initialize()} (a no-op in the selected
 * source) and registers the host wrapper factories the rule scripts meet. The
 * method touches no instance state, so it is invoked on an unattached App
 * instance created after the scratch storage binding and its context routing
 * are verified. The real {@code App.onCreate}, {@code attachBaseContext},
 * default-data seeding, logging, cronet pre-download, monitors and schedulers
 * never run.
 *
 * <p>The corpus declares the registration it requires; the measured registry is
 * compared with that declaration by factory identity, so a reference that
 * registers another set fails visibly instead of running without the wrapper
 * semantics the corpus expects.
 */
final class HostRuntimeInit {

    private static final String APP_CLASS = "io.legado.app.App";
    private static final String INIT_METHOD = "initRhino";
    private static final String WRAP_FACTORY_OBJECT = "com.script.rhino.RhinoWrapFactory";
    private static final String NATIVE_BASE_SOURCE =
        "io.legado.app.help.rhino.NativeBaseSource";
    private static final String READ_ONLY_JAVA_OBJECT = "com.script.rhino.ReadOnlyJavaObject";
    private static final String NATIVE_KIND = "native-base-source";
    private static final String READ_ONLY_KIND = "read-only-java-object";

    private HostRuntimeInit() {
    }

    /**
     * Creates an unattached App, invokes its own initialization method, and
     * returns the receipt the capture records. Every disagreement is a refusal:
     * a missing method, an attached instance, or a registry that is not exactly
     * the corpus declaration.
     */
    static JSONObject initialize(ClassLoader loader, JSONObject declaration) throws Exception {
        Class<?> appClass = loader.loadClass(APP_CLASS);
        Object app = appClass.getDeclaredConstructor().newInstance();
        ContextWrapper base = (ContextWrapper) app;
        if (base.getBaseContext() != null) {
            throw new IllegalStateException("the App instance is attached to "
                + base.getBaseContext()
                + "; the selected-reference initialization must not start the real lifecycle");
        }
        Method init;
        try {
            init = appClass.getDeclaredMethod(INIT_METHOD);
        } catch (NoSuchMethodException absent) {
            throw new IllegalStateException("the reference has no " + APP_CLASS + "#"
                + INIT_METHOD + "(); refusing to run without its host initialization", absent);
        }
        init.setAccessible(true);
        try {
            init.invoke(app);
        } catch (InvocationTargetException error) {
            Throwable cause = error.getCause();
            throw new IllegalStateException("App#" + INIT_METHOD + " failed: " + cause, cause);
        }

        Map<String, String> measured = measureRegistrations(loader);
        Map<String, String> declared = declaredRegistrations(declaration);
        if (!measured.equals(declared)) {
            throw new IllegalStateException("host wrapper registration is " + measured
                + ", the corpus declares " + declared);
        }
        return new JSONObject()
            .put("method", APP_CLASS + "#" + INIT_METHOD + "()")
            .put("invokedOn", "unattached-instance")
            .put("applicationClass", appClass.getName())
            .put("applicationAttached", false)
            .put("engine", "com.script.rhino.RhinoScriptEngine.initialize()")
            .put("registeredWrappers", new JSONObject(measured))
            .put("verified", true)
            .put("notRun", new JSONArray()
                .put("io.legado.app.App.onCreate")
                .put("io.legado.app.App.attachBaseContext")
                .put("io.legado.app.help.DefaultData.upVersion")
                .put("io.legado.app.help.http.Cronet.preDownload")
                .put("io.legado.app.help.AppFreezeMonitor.init")
                .put("io.legado.app.service.AutoTaskScheduler.refresh")
                .put("com.jeremyliao.liveeventbus.LiveEventBus.config"));
    }

    /** The wrapper registry the reference itself just published, type to kind. */
    private static Map<String, String> measureRegistrations(ClassLoader loader) throws Exception {
        Object factoryObject = loader.loadClass(WRAP_FACTORY_OBJECT).getField("INSTANCE")
            .get(null);
        Field factories = factoryObject.getClass().getDeclaredField("factories");
        factories.setAccessible(true);
        Object registered = factories.get(factoryObject);
        if (!(registered instanceof Map)) {
            throw new IllegalStateException("the reference's wrapper registry is not a map: "
                + registered);
        }
        Object nativeFactory = companionFactory(loader, NATIVE_BASE_SOURCE);
        Object readOnlyFactory = companionFactory(loader, READ_ONLY_JAVA_OBJECT);
        Map<String, String> measured = new TreeMap<>();
        for (Map.Entry<?, ?> entry : ((Map<?, ?>) registered).entrySet()) {
            if (!(entry.getKey() instanceof Class)) {
                throw new IllegalStateException("the wrapper registry keys "
                    + entry.getKey() + " is not a class");
            }
            Object factory = entry.getValue();
            String kind = factory == nativeFactory ? NATIVE_KIND
                : factory == readOnlyFactory ? READ_ONLY_KIND
                : factory == null ? "null" : factory.getClass().getName();
            measured.put(((Class<?>) entry.getKey()).getName(), kind);
        }
        return measured;
    }

    /** {@code BaseSource.Companion.factory}, the singleton {@code initRhino} registers. */
    private static Object companionFactory(ClassLoader loader, String className) throws Exception {
        Object companion = loader.loadClass(className).getField("Companion").get(null);
        return companion.getClass().getMethod("getFactory").invoke(companion);
    }

    /** The corpus' required registration, refusing a duplicate or unknown kind. */
    private static Map<String, String> declaredRegistrations(JSONObject declaration)
            throws JSONException {
        JSONArray rows = declaration.getJSONArray("registrations");
        Map<String, String> declared = new TreeMap<>();
        for (int index = 0; index < rows.length(); index++) {
            JSONObject row = rows.getJSONObject(index);
            String type = row.getString("type");
            String kind = row.getString("factory");
            if (!NATIVE_KIND.equals(kind) && !READ_ONLY_KIND.equals(kind)) {
                throw new IllegalStateException("the corpus declares an unknown wrapper kind "
                    + kind + " for " + type);
            }
            if (declared.put(type, kind) != null) {
                throw new IllegalStateException("the corpus declares " + type + " twice");
            }
        }
        if (declared.isEmpty()) {
            throw new IllegalStateException("the corpus declares no required wrapper");
        }
        return declared;
    }
}
