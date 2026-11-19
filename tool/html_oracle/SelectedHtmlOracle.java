package io.liber.oracle.nested;

import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Collection;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Iterator;
import java.util.HashSet;
import java.util.Set;

/** Fixed selected-reference HTML entry; the corpus is the packaged asset only. */
public final class SelectedHtmlOracle extends Instrumentation {
    private static final String TARGET = "com.legado.app.debug";
    private static final String PACKAGE = "io.liber.oracle.html.selected";
    private static final String BASELINE = "a7d37f1707a70a459ad708f4fe79341d1e42d716";
    private static final String TARGET_SHA = "593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5";
    private static final String PREFIX = "liber_html_selected_";
    private StateSessionOracle.ScratchContext scratch;
    private Object rootJob;
    private Method getChildren, isCompleted, isActive, sequenceIterator;
    private boolean terminalProved;

    @Override public Application newApplication(ClassLoader loader, String name, Context context)
            throws InstantiationException, IllegalAccessException, ClassNotFoundException {
        scratch = new StateSessionOracle.ScratchContext(context, "liber-html-selected", PREFIX, true);
        return Instrumentation.newApplication(GuardedReaderApplication.class, scratch);
    }

    @Override public boolean onException(Object object, Throwable error) {
        return (scratch != null && scratch.handleShortcutException(object, error))
            || super.onException(object, error);
    }

    @Override public void onCreate(Bundle args) {
        super.onCreate(args);
        new Handler(Looper.getMainLooper()).post(() ->
            new Thread(this::runSelected, "selected-html-oracle").start());
    }

    private static byte[] read(InputStream input) throws Exception {
        try (InputStream in = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192]; int n;
            while ((n = in.read(buffer)) != -1) out.write(buffer, 0, n);
            return out.toByteArray();
        }
    }

    private static String hash(byte[] bytes) throws Exception {
        StringBuilder text = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(bytes)) {
            text.append(Character.forDigit((b >> 4) & 15, 16));
            text.append(Character.forDigit(b & 15, 16));
        }
        return text.toString();
    }

    private static String fileHash(String path) throws Exception {
        return hash(read(new FileInputStream(path)));
    }

    private void setupJobOwner(ClassLoader loader) throws Exception {
        Field field = loader.loadClass("io.legado.app.help.coroutine.Coroutine").getDeclaredField("DEFAULT");
        field.setAccessible(true);
        Object scope = field.get(null);
        Class<?> scopeType = loader.loadClass("kotlinx.coroutines.CoroutineScope");
        Object context = scopeType.getMethod("getCoroutineContext").invoke(scope);
        Class<?> contextType = loader.loadClass("kotlin.coroutines.CoroutineContext");
        Class<?> keyType = loader.loadClass("kotlin.coroutines.CoroutineContext$Key");
        Class<?> jobType = loader.loadClass("kotlinx.coroutines.Job");
        rootJob = contextType.getMethod("get", keyType).invoke(context, jobType.getField("Key").get(null));
        if (rootJob == null || !jobType.isInstance(rootJob)) throw new IllegalStateException("DEFAULT Job absent");
        getChildren = jobType.getMethod("getChildren");
        isCompleted = jobType.getMethod("isCompleted");
        isActive = jobType.getMethod("isActive");
        sequenceIterator = loader.loadClass("kotlin.sequences.Sequence").getMethod("iterator");
        children();
    }

    private Set<Object> children() throws Exception {
        if (!(Boolean) isActive.invoke(rootJob) || (Boolean) isCompleted.invoke(rootJob))
            throw new IllegalStateException("DEFAULT Job is not active");
        Iterator<?> iterator = (Iterator<?>) sequenceIterator.invoke(getChildren.invoke(rootJob));
        Set<Object> result = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        while (iterator.hasNext()) result.add(iterator.next());
        return result;
    }

    private JSONObject awaitQuiescence() throws Exception {
        Set<Object> seen = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        long deadline = android.os.SystemClock.elapsedRealtime() + 10000;
        while (true) {
            seen.addAll(children()); boolean completed = true;
            for (Object job : seen) completed &= (Boolean) isCompleted.invoke(job);
            if (GuardedReaderApplication.launchAttempts() != 0) throw new IllegalStateException("activity launch attempted");
            if (completed && children().isEmpty()) return new JSONObject().put("owner", "Coroutine.DEFAULT Job")
                .put("observedChildren", seen.size()).put("allCompleted", true).put("rootEmpty", true)
                .put("launchAttempts", 0);
            if (android.os.SystemClock.elapsedRealtime() >= deadline) throw new IllegalStateException("DEFAULT Job did not reach quiescence");
            Thread.sleep(20);
        }
    }

    private void runSelected() {
        JSONObject report = new JSONObject(); boolean ok = false; Object database = null;
        try {
            byte[] bytes = read(getContext().getAssets().open("html-fixtures.json"));
            byte[] provenanceBytes = read(getContext().getAssets().open("provenance.json"));
            JSONObject corpus = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
            JSONObject provenance = new JSONObject(new String(provenanceBytes, StandardCharsets.UTF_8).replace("\uFEFF", ""));
            String fixture = corpus.getString("fixtureId");
            if (!("HTML-SELECTED-01".equals(fixture) || "HTML-LIST-SELECTED-01".equals(fixture))
                    || corpus.getInt("corpusVersion") != 1 || !BASELINE.equals(corpus.getString("baselineCommit"))
                    || !TARGET.equals(corpus.getJSONObject("target").getString("package"))
                    || !TARGET_SHA.equals(corpus.getJSONObject("target").getString("apkSha256"))
                    || !TARGET.equals(getTargetContext().getPackageName())
                    || !PACKAGE.equals(getContext().getPackageName())
                    || !BASELINE.equals(provenance.getString("baselineCommit"))
                    || !hash(bytes).equals(provenance.getString("corpusAssetSha256"))) {
                throw new IllegalStateException("selected corpus or package identity differs");
            }
            String targetPath = getTargetContext().getApplicationInfo().sourceDir;
            String harnessPath = getContext().getApplicationInfo().sourceDir;
            String targetHash = fileHash(targetPath);
            if (!TARGET_SHA.equals(targetHash)) throw new IllegalStateException("target APK differs");
            JSONObject identity = new JSONObject().put("fixtureId", fixture).put("corpusVersion", 1)
                .put("corpusAssetSha256", hash(bytes))
                .put("corpusSha256Lf", hash(new String(bytes, StandardCharsets.UTF_8).replace("\r\n", "\n").getBytes(StandardCharsets.UTF_8)))
                .put("provenanceAssetSha256", hash(provenanceBytes))
                .put("targetPackage", TARGET).put("targetApkSha256", targetHash).put("targetApkPath", targetPath)
                .put("harnessPackage", PACKAGE).put("harnessApkSha256", fileHash(harnessPath))
                .put("harnessApkPath", harnessPath);
            report.put("identity", identity).put("provenance", provenance)
                .put("baselineCommit", BASELINE).put("entryPoint", corpus.getString("entryPoint"))
                .put("fingerprint", Build.FINGERPRINT)
                .put("corpus", new JSONObject().put("asset", "html-fixtures.json").put("bytes", bytes.length)
                    .put("sha256", hash(bytes)).put("fixtureId", fixture).put("corpusVersion", 1)
                    .put("schemaVersion", corpus.getInt("schemaVersion")))
                .put("startupContainment", scratch.shortcutReceipt());
            scratch.bindRun(identity);
            ClassLoader loader = getTargetContext().getClassLoader();
            Context app = (Context) loader.loadClass("splitties.init.AppCtxKt").getMethod("getAppCtx").invoke(null);
            if (!(app instanceof GuardedReaderApplication) || !app.getFilesDir().equals(scratch.getFilesDir())
                    || !app.getDatabasePath("legado.db").equals(scratch.getDatabasePath("legado.db"))) {
                throw new IllegalStateException("appCtx escaped scratch storage");
            }
            File prefs = new File(getTargetContext().getApplicationInfo().dataDir, "shared_prefs");
            JSONObject probe = scratch.seedProbePreferences(app, prefs, "html_probe");
            if (!probe.getBoolean("registered") || !probe.getBoolean("committed")
                    || !probe.getBoolean("scopedFile") || probe.getBoolean("installationFile")) {
                throw new IllegalStateException("scratch preference probe failed");
            }
            report.put("isolation", new JSONObject().put("verified", true).put("preferenceProbe", probe)
                .put("scratchRoot", scratch.root.toString()).put("application", app.getClass().getName()));
            report.put("hostInitialization", HostRuntimeInit.initialize(loader, corpus.getJSONObject("hostInitialization")));
            database = loader.loadClass("io.legado.app.data.AppDatabaseKt").getMethod("getAppDb").invoke(null);
            setupJobOwner(loader);
            if (!children().isEmpty()) throw new IllegalStateException("DEFAULT Job already has children");
            terminalProved = true;
            report.put("terminalOwner", new JSONObject().put("scope", "Coroutine.DEFAULT")
                .put("baselineChildren", 0).put("rootActive", true).put("rootCompleted", false)
                .put("childrenMethod", getChildren.toString()).put("completionMethod", isCompleted.toString()));
            Class<?> ruleClass = loader.loadClass("io.legado.app.model.analyzeRule.AnalyzeRule");
            Class<?> dataClass = loader.loadClass("io.legado.app.model.analyzeRule.RuleDataInterface");
            Class<?> sourceClass = loader.loadClass("io.legado.app.data.entities.BaseSource");
            Constructor<?> ctor = ruleClass.getConstructor(dataClass, sourceClass, boolean.class, boolean.class);
            Method setContent = ruleClass.getMethod("setContent", Object.class, String.class);
            Method scalar = ruleClass.getMethod("getString", String.class, Object.class, boolean.class);
            Method list = ruleClass.getMethod("getStringList", String.class, Object.class, boolean.class);
            report.put("entryPoints", new JSONObject().put("constructor", ctor.toString())
                .put("setContent", setContent.toString()).put("getString", scalar.toString())
                .put("getStringList", list.toString()));
            JSONObject documents = corpus.getJSONObject("documents"); JSONArray cases = corpus.getJSONArray("cases");
            int expected = "HTML-SELECTED-01".equals(fixture) ? 45 : 11;
            if (cases.length() != expected) throw new IllegalStateException("selected case count differs");
            JSONArray rows = new JSONArray(); report.put("observations", rows); Set<String> ids = new HashSet<>();
            for (int i = 0; i < cases.length(); i++) {
                JSONObject entry = cases.getJSONObject(i); String id = entry.getString("id");
                if (id.isEmpty() || !ids.add(id)) throw new IllegalStateException("duplicate or empty case id");
                JSONObject row = new JSONObject().put("id", id); rows.put(row);
                if (!children().isEmpty()) throw new IllegalStateException("DEFAULT Job active before row");
                terminalProved = false;
                Object rule = ctor.newInstance(null, null, false, false);
                setContent.invoke(rule, documents.getString(entry.getString("document")), corpus.getString("baseUrl"));
                String method = entry.optString("method", "getString");
                boolean isList = "getStringList".equals(method) || "getStringListUrl".equals(method);
                boolean isUrl = "getStringUrl".equals(method) || "getStringListUrl".equals(method);
                if (!(isList || "getString".equals(method) || "getStringUrl".equals(method)))
                    throw new IllegalStateException("unknown selected method " + method);
                try {
                    Object value = (isList ? list : scalar).invoke(rule, entry.getString("rule"), null, isUrl);
                    row.put("value", value instanceof Collection<?> ? new JSONArray((Collection<?>) value)
                        : value == null ? JSONObject.NULL : value);
                } catch (InvocationTargetException error) {
                    Throwable cause = error.getCause(); row.put("error", (cause == null ? error : cause).getClass().getName());
                }
                row.put("terminal", awaitQuiescence());
                terminalProved = true;
            }
            if (GuardedReaderApplication.launchAttempts() != 0) throw new IllegalStateException("activity launch attempted");
            ok = true;
        } catch (Throwable error) {
            if (scratch != null) scratch.refuseWaiters(error.toString());
            try { report.put("failure", error.toString()); } catch (Exception ignored) { }
        } finally {
            try {
                boolean closed = false;
                if (database != null && terminalProved) {
                    database.getClass().getMethod("close").invoke(database);
                    closed = true;
                }
                JSONObject cleanup = new JSONObject().put("activityLaunchAttempts", GuardedReaderApplication.launchAttempts())
                    .put("databaseClosed", closed).put("terminalProved", terminalProved)
                    .put("scratchRemoved", false).put("scratchRetained", scratch != null && scratch.root.exists());
                if (ok && closed && scratch.isBound()) {
                    JSONArray removed = new JSONArray(); boolean preferencesRemoved = true;
                    Set<String> registered = scratch.ownedPreferences();
                    cleanup.put("registeredPreferences", new JSONArray(registered));
                    for (String name : registered) {
                        boolean deleted = scratch.deletePreference(name); preferencesRemoved &= deleted;
                        removed.put(new JSONObject().put("name", name).put("ok", deleted));
                    }
                    boolean rootRemoved = preferencesRemoved && scratch.removeRoot();
                    cleanup.put("preferencesRemoved", removed).put("scratchRemoved", rootRemoved)
                        .put("scratchRetained", !rootRemoved && scratch.root.exists());
                    ok = rootRemoved && preferencesRemoved;
                } else ok = false;
                report.put("cleanup", cleanup);
            } catch (Throwable error) {
                ok = false; try { report.put("cleanupFailure", error.toString()); } catch (Exception ignored) { }
            }
            Bundle status = new Bundle();
            status.putString("stream", "HTML_ORACLE_BASE64=" + Base64.encodeToString(
                report.toString().getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP) + "\n");
            finish(ok ? -1 : 1, status);
        }
    }
}
