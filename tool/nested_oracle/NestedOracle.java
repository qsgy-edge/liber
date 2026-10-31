package io.liber.oracle.nested;

import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.lang.reflect.*;
import java.util.*;

/** Calls the installed, hash-pinned APK. No Legado production class is rebuilt. */
public class NestedOracle extends Instrumentation {

    /** The historical `14dd2494` JSLIB-01 corpus: unchanged, external-file delivery. */
    private static final String CORPUS_JSLIB = "jslib";
    /**
     * The selected-reference JSLIB-01 corpus: storage-only, host-initialized, and
     * delivered on the instrumentation stream. Selected by `-e corpus jslib-selected`
     * together with the selected-reference apk it pins.
     */
    private static final String CORPUS_JSLIB_SELECTED = "jslib-selected";
    private static final String STREAM_KEY = "JSLIB_ORACLE_BASE64";
    private static final String SCRATCH_ROOT_NAME = "liber-jslib-oracle";
    private static final String PREFERENCE_PREFIX = "liber_jslib_oracle_";
    private static final String PROBE_PREFERENCE = "liber_jslib_probe";

    private Bundle arguments;
    private StateSessionOracle.ScratchContext scratch;
    private ClassLoader loader;
    private boolean cleanupOk;
    private volatile String stage = "setup";

    // This must be fixed by the instrumentation class, not extras: Android calls
    // newApplication and installs providers before Instrumentation.onCreate.
    boolean storageOnly() { return false; }

    @Override
    public void onCreate(Bundle args) {
        arguments = args;
        super.onCreate(args);
        String corpus = args == null ? null : args.getString("corpus");
        if (storageOnly() != CORPUS_JSLIB_SELECTED.equals(corpus)) {
            Bundle status = new Bundle();
            status.putString("stream", "Wrong instrumentation entry or corpus; refusing.\n");
            finish(1, status);
            return;
        }
        start();
    }

    @Override
    public Application newApplication(ClassLoader cl, String name, Context context)
            throws InstantiationException, IllegalAccessException, ClassNotFoundException {
        if (!storageOnly()) return super.newApplication(cl, name, context);
        // The selected reference is measured storage-only: the installed
        // io.legado.app.App is never instantiated, so its onCreate, attachBaseContext,
        // default-data seeding, cronet pre-download, monitors and jobs never run.
        scratch = new StateSessionOracle.ScratchContext(context, SCRATCH_ROOT_NAME,
            PREFERENCE_PREFIX);
        return super.newApplication(cl, Application.class.getName(), scratch);
    }

    @Override
    public void onStart() {
        if (!storageOnly()) {
            runHistorical();
            return;
        }
        // The scratch binding needs the process' application (and the start-up
        // providers that reach it) to exist, so the selected run starts from the main
        // looper and does its work on a worker thread, exactly as the state oracle does.
        new Handler(Looper.getMainLooper()).post(
            () -> new Thread(this::runSelected, "jslib-oracle-selected").start());
        startWatchdog();
    }

    // ------------------------------------------------------------- historical

    /**
     * The historical behavior, unchanged: the default JS oracle and `-e corpus jslib`
     * run in the process the installed application created, and the report is written
     * to the target's external files directory.
     */
    private void runHistorical() {
        Bundle status = new Bundle();
        try (Replay replay = new Replay()) {
            boolean jsLib = CORPUS_JSLIB.equals(
                arguments == null ? null : arguments.getString("corpus"));
            String asset = jsLib ? "jslib-fixtures.json" : "fixtures.json";
            byte[] fixtureBytes = readAsset(asset);
            JSONObject corpus = new JSONObject(new String(fixtureBytes, StandardCharsets.UTF_8));
            // The jsLib capture is only labelled frozen after the installed
            // target's own package and APK bytes are measured and verified
            // against the pin the corpus carries. Nothing is written if either
            // disagrees, so a same-package substitute build cannot be captured
            // under the frozen label.
            String targetPackage = null;
            String targetApkPath = null;
            String targetApkSha256 = null;
            if (jsLib) {
                JSONObject target = corpus.getJSONObject("target");
                targetPackage = getTargetContext().getPackageName();
                targetApkPath = getTargetContext().getApplicationInfo().sourceDir;
                targetApkSha256 = sha256(readAll(new File(targetApkPath)));
                if (!targetPackage.equals(target.getString("package"))) {
                    throw new IllegalStateException(
                        "Frozen target package mismatch: measured " + targetPackage
                            + ", pin " + target.getString("package"));
                }
                if (!targetApkSha256.equals(target.getString("apkSha256"))) {
                    throw new IllegalStateException(
                        "Frozen target APK mismatch: measured " + targetApkSha256
                            + ", pin " + target.getString("apkSha256"));
                }
            }
            JSONArray observations = observe(corpus, replay, null);
            JSONObject report = new JSONObject()
                .put("baselineCommit", corpus.getString("baselineCommit"))
                .put("fingerprint", Build.FINGERPRINT)
                .put("entryPoint", corpus.getString("entryPoint"))
                .put("observations", observations).put("requests", replay.requests);
            if (jsLib) {
                // The comparator refuses to compare without this identity, the
                // corpus hash and the measured frozen-capture provenance block.
                report.put("fixtureId", corpus.getString("fixtureId"));
                report.put("corpusVersion", corpus.getInt("corpusVersion"));
                report.put("corpusSha256", sha256Lf(fixtureBytes));
                report.put("provenance", provenance(corpus, Build.FINGERPRINT, targetPackage,
                    targetApkPath, targetApkSha256));
            }
            File output = new File(getTargetContext().getExternalFilesDir(null),
                jsLib ? "jslib-oracle.json" : "nested-oracle.json");
            try (FileOutputStream stream = new FileOutputStream(output)) {
                stream.write(report.toString(2).getBytes(StandardCharsets.UTF_8));
            }
            status.putString("stream", (jsLib ? "jsLib oracle" : "Nested oracle")
                + " recorded " + observations.length() + " observations\n");
            finish(-1, status);
        } catch (Throwable error) {
            status.putString("stream", error.toString() + "\n");
            finish(1, status);
        }
    }

    // --------------------------------------------------------------- selected

    /**
     * The selected-reference run: measure the installed target, bind a fresh owned
     * scratch root, verify the context routing, perform the reference's own host
     * initialization, record the corpus' steps, then remove everything it created.
     *
     * <p>The report leaves through the BASE64 instrumentation stream and no report
     * file is written, so the cleanup that removes the owned root cannot lose it.
     */
    private void runSelected() {
        Bundle status = new Bundle();
        JSONObject report = new JSONObject();
        boolean ok = false;
        String failure = null;
        JSONObject cleanup = new JSONObject();
        int observed = 0;
        try {
            JSONObject corpus;
            byte[] fixtureBytes;
            String targetPackage;
            String targetApkPath;
            String targetApkSha256;
            JSONObject identity;
            try (Replay replay = new Replay()) {
                stage = "identity";
                fixtureBytes = readAsset("jslib-fixtures-selected.json");
                corpus = new JSONObject(new String(fixtureBytes, StandardCharsets.UTF_8));
                JSONObject target = corpus.getJSONObject("target");
                targetPackage = getTargetContext().getPackageName();
                targetApkPath = getTargetContext().getApplicationInfo().sourceDir;
                targetApkSha256 = sha256(readAll(new File(targetApkPath)));
                if (!targetPackage.equals(target.getString("package"))) {
                    throw new IllegalStateException("Frozen target package mismatch: measured "
                        + targetPackage + ", pin " + target.getString("package"));
                }
                if (!targetApkSha256.equals(target.getString("apkSha256"))) {
                    throw new IllegalStateException("Frozen target APK mismatch: measured "
                        + targetApkSha256 + ", pin " + target.getString("apkSha256"));
                }
                String harnessPackage = getContext().getPackageName();
                String harnessPath = getContext().getPackageManager()
                    .getApplicationInfo(harnessPackage, 0).sourceDir;
                identity = new JSONObject()
                    .put("fixtureId", corpus.getString("fixtureId"))
                    .put("corpusVersion", corpus.getInt("corpusVersion"))
                    .put("corpusSha256Lf", sha256Lf(fixtureBytes))
                    .put("targetPackage", targetPackage)
                    .put("targetApkPath", targetApkPath)
                    .put("targetApkSha256", targetApkSha256)
                    .put("targetBaselineCommit", target.getString("baselineCommit"))
                    .put("targetPinManifest", target.getString("manifest"))
                    .put("harnessPackage", harnessPackage)
                    .put("harnessApkPath", harnessPath)
                    .put("harnessApkSha256", sha256(readAll(new File(harnessPath))))
                    .put("corpusAsset", "jslib-fixtures-selected.json")
                    .put("corpusAssetSha256", sha256(fixtureBytes));
                report.put("fixtureId", corpus.getString("fixtureId"))
                    .put("corpusVersion", corpus.getInt("corpusVersion"))
                    .put("baselineCommit", corpus.getString("baselineCommit"))
                    .put("entryPoint", corpus.getString("entryPoint"))
                    .put("corpusSha256", sha256Lf(fixtureBytes))
                    .put("platform", "android")
                    .put("fingerprint", Build.FINGERPRINT)
                    .put("recordedAt", timestamp())
                    .put("identity", identity);

                if (scratch == null) {
                    throw new IllegalStateException("no storage-only application was installed"
                        + " for this run; refusing selected-reference capture");
                }
                stage = "binding";
                scratch.bindRun(identity);
                loader = getTargetContext().getClassLoader();
                report.put("isolation", checkScratchRouting());
                stage = "hostInitialization";
                report.put("hostInitialization", HostRuntimeInit.initialize(loader,
                    corpus.getJSONObject("hostInitialization")));
                stage = "steps";
                JSONObject bindings = new JSONObject();
                JSONArray observations = observe(corpus, replay, bindings);
                observed = observations.length();
                report.put("bindings", bindings)
                    .put("observations", observations)
                    .put("requests", replay.requests)
                    .put("provenance", provenance(corpus, Build.FINGERPRINT, targetPackage,
                        targetApkPath, targetApkSha256));
            }
            // Reaching here means the replay server closed with its worker stopped.
            report.put("replayServerClosed", true);
            ok = true;
        } catch (Throwable error) {
            failure = describe(error);
            if (scratch != null) scratch.refuseWaiters(failure);
            log("selected run failed in stage " + stage + ": " + failure);
        } finally {
            stage = "cleanup";
            try {
                if (scratch == null || !scratch.isBound()) {
                    cleanup = new JSONObject()
                        .put("ownership", "unbound: existing or partially created root preserved")
                        .put("scratchRemoved", false)
                        .put("scratchRoot", scratch == null ? JSONObject.NULL
                            : scratch.root.getAbsolutePath());
                    ok = false;
                } else {
                    cleanup = cleanupRun();
                    ok = ok && cleanupOk;
                }
            } catch (Throwable error) {
                ok = false;
                if (failure == null) failure = "cleanup: " + describe(error);
                try {
                    cleanup.put("cleanupFailure", describe(error));
                } catch (Exception ignored) {
                    // The human line on the stream still carries the stage.
                }
            }
            try {
                report.put("cleanup", cleanup)
                    .put("reportDelivery",
                        "JSLIB_ORACLE_BASE64 instrumentation stream; no report file is"
                            + " written, so removing the owned root cannot lose the report")
                    .put("analysisFailure", failure == null ? JSONObject.NULL : failure);
            } catch (Exception error) {
                ok = false;
                failure = (failure == null ? "" : failure + " | ")
                    + "report assembly: " + describe(error);
            }
            status.putString("stream", STREAM_KEY + "=" + base64(report.toString()) + "\n"
                + "Selected reference JSLIB oracle: "
                + (failure == null ? "recorded " + observed + " observations"
                    : "failed: " + failure) + "\n");
            finish(ok ? -1 : 1, status);
        }
    }

    /**
     * The selected corpus' own storage check: the frozen code's context must route into
     * the owned root, and the preference namespace it meets must be the task's, not the
     * installed application's.
     */
    private JSONObject checkScratchRouting() throws Exception {
        Context app = (Context) loader.loadClass("splitties.init.AppCtxKt")
            .getMethod("getAppCtx").invoke(null);
        if (!app.getFilesDir().equals(scratch.getFilesDir())) {
            throw new IllegalStateException("appCtx escaped the scratch files directory: "
                + app.getFilesDir());
        }
        if (!app.getDatabasePath("legado.db").equals(scratch.getDatabasePath("legado.db"))) {
            throw new IllegalStateException("appCtx escaped the scratch database directory: "
                + app.getDatabasePath("legado.db"));
        }
        File dataDir = new File(getTargetContext().getApplicationInfo().dataDir, "shared_prefs");
        JSONObject probe = scratch.seedProbePreferences(app, dataDir, PROBE_PREFERENCE);
        if (probe.getBoolean("installationFile") || !probe.getBoolean("registered")
                || !probe.getBoolean("scopedFile")) {
            throw new IllegalStateException("appCtx preference storage is not scratch-scoped: "
                + probe);
        }
        return new JSONObject()
            .put("application", app.getClass().getName())
            .put("files", app.getFilesDir().toString())
            .put("database", app.getDatabasePath("legado.db").toString())
            .put("preferencesPrefix", PREFERENCE_PREFIX)
            .put("preferenceProbe", probe)
            .put("scratchRoot", scratch.root.getAbsolutePath())
            .put("scratchRootExistedAtStart", scratch.rootExistedAtStart())
            .put("processApplication", "android.app.Application over the scratch context:"
                + " io.legado.app.App.onCreate, attachBaseContext, default-data seeding,"
                + " cronet pre-download, monitors and schedulers do not run");
    }

    /** Removes the preference namespaces and the root this run created. */
    private JSONObject cleanupRun() throws Exception {
        JSONObject cleanup = new JSONObject();
        cleanupOk = false;
        JSONArray removed = new JSONArray();
        boolean allRemoved = true;
        for (String name : scratch.ownedPreferences()) {
            boolean removedOk = scratch.deletePreference(name);
            allRemoved &= removedOk;
            removed.put(new JSONObject().put("name", name).put("ok", removedOk));
        }
        boolean rootRemoved = scratch.removeRoot();
        cleanup.put("ownership", "created-fresh-root")
            .put("scratchRoot", scratch.root.getAbsolutePath())
            .put("preferencesRemoved", removed)
            .put("scratchRemoved", rootRemoved)
            .put("scratchRetained", !rootRemoved && scratch.root.exists())
            .put("reportFile", JSONObject.NULL);
        cleanupOk = allRemoved && rootRemoved;
        if (!cleanupOk) {
            cleanup.put("cleanupFailure", "everyPreferenceRemoved=" + allRemoved
                + " rootRemoved=" + rootRemoved);
        }
        return cleanup;
    }

    // ----------------------------------------------------------------- shared

    /**
     * Walks the corpus' declared steps against the installed target, in order. The
     * AnalyzeUrl constructor and evalJS entry point are resolved from the declaration;
     * the arity actually used is recorded when a capture asks for the receipt.
     */
    private JSONArray observe(JSONObject corpus, Replay replay, JSONObject bindings)
            throws Exception {
        ClassLoader target = getTargetContext().getClassLoader();
        Class<?> sourceClass = target.loadClass("io.legado.app.data.entities.BookSource");
        Class<?> urlClass = target.loadClass("io.legado.app.model.analyzeRule.AnalyzeUrl");
        Object context = target.loadClass("kotlin.coroutines.EmptyCoroutineContext")
            .getField("INSTANCE").get(null);
        Constructor<?> ctor = analyzeUrlConstructor(urlClass, sourceClass, bindings);
        Method eval = urlClass.getMethod("evalJS", String.class, Object.class);
        if (bindings != null) bindings.put("evalJS", signatureOf(eval));
        Map<String, Object> sources = new HashMap<>();
        JSONArray observations = new JSONArray();
        JSONArray steps = corpus.getJSONArray("steps");
        for (int i = 0; i < steps.length(); i++) {
            JSONObject step = steps.getJSONObject(i);
            String key = step.optString("sourceKey", "first");
            Object source = sources.get(key);
            if (source == null) {
                source = sourceClass.getConstructor().newInstance();
                sourceClass.getMethod("setBookSourceUrl", String.class)
                    .invoke(source, replay.origin + "/source/" + key);
                sourceClass.getMethod("setJsLib", String.class)
                    .invoke(source, corpus.getString("jsLib"));
                sources.put(key, source);
            }
            List<Object> values = new ArrayList<>(Arrays.asList(replay.origin + "/", "outer-key",
                Integer.valueOf(7), null, null, "", source, null, null, null, null, context, null,
                Boolean.TRUE));
            while (values.size() < ctor.getParameterCount()) values.add(null);
            Object url = ctor.newInstance(values.toArray());
            JSONObject result = new JSONObject().put("id", step.getString("id"));
            try {
                Object value = eval.invoke(url,
                    step.getString("script").replace("$ORIGIN", replay.origin), null);
                result.put("value", value == null ? JSONObject.NULL : value.toString());
            } catch (InvocationTargetException error) {
                result.put("error", error.getCause().getClass().getName());
            }
            observations.put(result);
        }
        return observations;
    }

    /**
     * The AnalyzeUrl constructor the corpus drives: the historical `14dd2494`
     * declaration has fourteen parameters and the selected reference adds the nullable
     * `infoMap` and `extraParams`. Both are resolved by declared type, never by assuming
     * the older arity, and the resolved declaration is recorded in the capture.
     */
    private static Constructor<?> analyzeUrlConstructor(Class<?> urlClass, Class<?> sourceClass,
            JSONObject bindings) throws Exception {
        String[] expected = {"java.lang.String", "java.lang.String", "java.lang.Integer",
            "java.lang.String", "java.lang.Integer", "java.lang.String",
            "io.legado.app.data.entities.BaseSource",
            "io.legado.app.model.analyzeRule.RuleDataInterface",
            "io.legado.app.data.entities.BookChapter", "java.lang.Long", "java.lang.Long",
            "kotlin.coroutines.CoroutineContext", "java.util.Map", "boolean"};
        // Selected capture must never silently fall back to the historical arity.
        Constructor<?> selected = null;
        int arity = bindings == null ? 14 : 16;
        for (Constructor<?> candidate : urlClass.getConstructors()) {
            Class<?>[] types = candidate.getParameterTypes();
            if (types.length != arity) continue;
            boolean matches = true;
            for (int index = 0; index < expected.length; index++) {
                matches &= types[index].getName().equals(expected[index]);
            }
            matches &= types[6].isAssignableFrom(sourceClass);
            if (arity == 16) matches &= types[14].equals(Map.class)
                && types[15].equals(Map.class);
            if (matches) {
                if (selected != null) throw new IllegalStateException("ambiguous AnalyzeUrl constructor");
                selected = candidate;
            }
        }
        if (selected == null) {
            throw new IllegalStateException("frozen AnalyzeUrl constructor absent: expected "
                + arity + " parameters with the source-verified types");
        }
        if (bindings != null) {
            JSONArray names = new JSONArray();
            for (Class<?> type : selected.getParameterTypes()) names.put(type.getName());
            bindings.put("analyzeUrlConstructorParameters", selected.getParameterCount())
                .put("analyzeUrlParameterTypes", names);
        }
        return selected;
    }

    private static String signatureOf(Method method) {
        StringBuilder text = new StringBuilder(method.getName()).append('(');
        Class<?>[] types = method.getParameterTypes();
        for (int index = 0; index < types.length; index++) {
            if (index > 0) text.append(',');
            text.append(types[index].getSimpleName());
        }
        return text.append(')').toString();
    }

    private static JSONObject provenance(JSONObject corpus, String fingerprint,
            String targetPackage, String targetApkPath, String targetApkSha256)
            throws Exception {
        JSONObject target = corpus.getJSONObject("target");
        return new JSONObject()
            .put("kind", "frozen-device-capture")
            .put("deviceFingerprint", fingerprint)
            .put("capturedAt", timestamp())
            .put("entryPoint", corpus.getString("entryPoint"))
            .put("baselineCommit", corpus.getString("baselineCommit"))
            .put("targetPackage", targetPackage)
            .put("targetApkPath", targetApkPath)
            .put("targetApkSha256", targetApkSha256)
            .put("targetPin", new JSONObject()
                .put("package", target.getString("package"))
                .put("apkSha256", target.getString("apkSha256"))
                .put("manifest", target.optString("manifest", "")));
    }

    private void startWatchdog() {
        Thread watchdog = new Thread(() -> {
            try {
                Thread.sleep(240000);
            } catch (InterruptedException interrupted) {
                return;
            }
            log("watchdog: no result after 240s; stage=" + stage);
            Bundle status = new Bundle();
            JSONObject report = new JSONObject();
            try {
                report.put("fixtureId", "JSLIB-01")
                    .put("corpusVersion", 3)
                    .put("baselineCommit", "a7d37f1707a70a459ad708f4fe79341d1e42d716")
                    .put("entryPoint", "AnalyzeUrl.evalJS shared-jsLib scope")
                    .put("platform", "android")
                    .put("fingerprint", Build.FINGERPRINT)
                    .put("timedOut", true)
                    .put("timeoutStage", stage)
                    .put("analysisFailure", "timeout: no result after 240s in stage " + stage);
            } catch (Exception error) {
                // The human line below still names the stage.
            }
            status.putString("stream", STREAM_KEY + "=" + base64(report.toString()) + "\n"
                + "Selected reference JSLIB oracle: timed out in stage " + stage + "\n");
            finish(1, status);
        }, "jslib-oracle-watchdog");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    private void log(String message) {
        android.util.Log.i("NestedOracle", message);
    }

    private static String describe(Throwable error) {
        StringBuilder text = new StringBuilder(error.toString());
        Throwable cause = error.getCause();
        while (cause != null) {
            text.append(" <- ").append(cause);
            cause = cause.getCause();
        }
        return text.toString();
    }

    private static String base64(String text) {
        return android.util.Base64.encodeToString(text.getBytes(StandardCharsets.UTF_8),
            android.util.Base64.NO_WRAP);
    }

    private static String timestamp() {
        return new java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US)
            .format(new Date());
    }

    private byte[] readAsset(String name) throws IOException {
        try (InputStream input = getContext().getAssets().open(name)) {
            return input.readAllBytes();
        }
    }

    /** SHA-256 of the corpus bytes with CRLF normalized to LF, so one pin means
     *  the same corpus on a Windows and an LF checkout. */
    static String sha256Lf(byte[] bytes) throws Exception {
        String text = new String(bytes, StandardCharsets.UTF_8).replace("\r\n", "\n");
        return sha256(text.getBytes(StandardCharsets.UTF_8));
    }

    /** Raw SHA-256 of the installed target APK bytes. */
    static String sha256(byte[] bytes) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
        StringBuilder hex = new StringBuilder();
        for (byte value : digest) hex.append(String.format("%02x", value));
        return hex.toString();
    }

    static byte[] readAll(File file) throws Exception {
        try (InputStream input = new FileInputStream(file)) {
            return input.readAllBytes();
        }
    }

    static final class Replay implements AutoCloseable {
        final ServerSocket server = new ServerSocket(18763, 16, InetAddress.getByName("127.0.0.1"));
        final String origin = "http://127.0.0.1:18763";
        final JSONArray requests = new JSONArray();
        final Thread worker;
        Replay() throws IOException {
            worker = new Thread(() -> {
                while (!server.isClosed()) {
                    try (Socket client = server.accept()) {
                        client.setSoTimeout(10000);
                        BufferedReader input = new BufferedReader(new InputStreamReader(client.getInputStream(), StandardCharsets.UTF_8));
                        String line = input.readLine();
                        if (line == null) continue;
                        String[] request = line.split(" ", 3);
                        String rawPath = request[1];
                        synchronized (requests) { requests.put(request[0] + " " + rawPath); }
                        while ((line = input.readLine()) != null && !line.isEmpty()) { }
                        String path = URLDecoder.decode(rawPath, "UTF-8");
                        byte[] body = (path.startsWith("/value/") ? path.substring(7) : "").getBytes(StandardCharsets.UTF_8);
                        OutputStream output = client.getOutputStream();
                        output.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: " + body.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                        output.write(body);
                        output.flush();
                    } catch (IOException error) {
                        if (!server.isClosed()) synchronized (requests) { requests.put("SERVER_ERROR " + error.getClass().getName()); }
                    }
                }
            }, "nested-oracle-replay");
            worker.start();
        }
        public void close() throws Exception { server.close(); worker.join(1000); if (worker.isAlive()) throw new IllegalStateException("Replay worker did not stop"); }
    }
}
