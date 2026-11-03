package io.liber.oracle.nested;

import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import io.liber.oracle.replace.ReaderOracle;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Set;

/** Selected-reference reader entry; no extras can select a different corpus or target. */
public final class SelectedReaderOracle extends ReaderOracle {
    private static final String PACKAGE = "io.liber.oracle.replace.selected";
    private static final String TARGET = "com.legado.app.debug";
    private static final String BASELINE = "a7d37f1707a70a459ad708f4fe79341d1e42d716";
    private static final String APK_SHA = "593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5";
    private static final String PREFIX = "liber_replace_selected_";
    private StateSessionOracle.ScratchContext scratch;
    private Method titleMethod;
    private Method contentMethod;
    private Object rootJob;
    private Method getChildren;
    private Method isCompleted;
    private Method isActive;
    private Method sequenceIterator;
    private boolean terminalProved;
    private JSONArray readerCalls;

    @Override public Application newApplication(ClassLoader cl, String name, Context context)
            throws InstantiationException, IllegalAccessException, ClassNotFoundException {
        scratch = new StateSessionOracle.ScratchContext(context, "liber-replace-selected", PREFIX, true);
        return Instrumentation.newApplication(GuardedReaderApplication.class, scratch);
    }

    @Override public boolean onException(Object object, Throwable error) {
        return (scratch != null && scratch.handleShortcutException(object, error))
            || super.onException(object, error);
    }

    @Override public void onCreate(Bundle args) {
        startInstrumentation(args);
        startSelected();
    }

    private void startSelected() {
        new Handler(Looper.getMainLooper()).post(() -> new Thread(this::runSelected,
            "selected-reader-oracle").start());
    }

    private byte[] readAll(InputStream input) throws Exception {
        try (InputStream in = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            return out.toByteArray();
        }
    }

    private String fileHash(String path) throws Exception { return hash(readAll(new FileInputStream(path))); }

    private void runSelected() {
        JSONObject report = new JSONObject();
        boolean ok = false;
        Object database = null;
        try {
            byte[] bytes = readAll(getContext().getAssets().open("fixtures-selected.json"));
            JSONObject corpus = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
            if (!"REPLACE-17".equals(corpus.getString("fixtureId")) || corpus.getInt("corpusVersion") != 2
                    || !BASELINE.equals(corpus.getString("baselineCommit"))
                    || !TARGET.equals(corpus.getJSONObject("target").getString("package"))
                    || !APK_SHA.equals(corpus.getJSONObject("target").getString("apkSha256"))
                    || !TARGET.equals(getTargetContext().getPackageName())
                    || !PACKAGE.equals(getContext().getPackageName())) {
                throw new IllegalStateException("selected corpus or package identity differs");
            }
            String targetApk = getTargetContext().getApplicationInfo().sourceDir;
            String harnessApk = getContext().getApplicationInfo().sourceDir;
            String targetHash = fileHash(targetApk);
            if (!APK_SHA.equals(targetHash)) throw new IllegalStateException("target APK differs");
            String lfHash = hash(new String(bytes, StandardCharsets.UTF_8)
                .replace("\r\n", "\n").getBytes(StandardCharsets.UTF_8));
            byte[] provenanceBytes = readAll(getContext().getAssets().open("provenance.json"));
            String provenanceText = new String(provenanceBytes, StandardCharsets.UTF_8).replace("\uFEFF", "");
            JSONObject provenance = new JSONObject(provenanceText);
            if (!BASELINE.equals(provenance.getString("baselineCommit")) ||
                    !lfHash.equals(provenance.getString("corpusSha256Lf")) ||
                    !hash(bytes).equals(provenance.getString("corpusAssetSha256"))) {
                throw new IllegalStateException("packaged provenance does not bind corpus");
            }
            report.put("provenance", provenance);
            JSONObject identity = new JSONObject().put("fixtureId", "REPLACE-17")
                .put("corpusVersion", 2).put("corpusSha256Lf", lfHash)
                .put("corpusAssetSha256", hash(bytes)).put("provenanceAssetSha256", hash(provenanceBytes)).put("targetPackage", TARGET)
                .put("targetApkSha256", targetHash).put("targetApkPath", targetApk)
                .put("harnessPackage", PACKAGE).put("harnessApkPath", harnessApk)
                .put("harnessApkSha256", fileHash(harnessApk));
            report.put("identity", identity).put("fixtureId", "REPLACE-17")
                .put("corpusVersion", 2).put("baselineCommit", BASELINE)
                .put("fixtureSha256", lfHash).put("boundary", corpus.getString("comparisonBoundary"))
                .put("fingerprint", Build.FINGERPRINT);
            report.put("startupContainment", scratch.shortcutReceipt());
            scratch.bindRun(identity);
            loader = getTargetContext().getClassLoader();
            Context app = (Context) loader.loadClass("splitties.init.AppCtxKt").getMethod("getAppCtx").invoke(null);
            if (!(app instanceof GuardedReaderApplication)) {
                throw new IllegalStateException("appCtx is not the guarded reader application");
            }
            if (!app.getFilesDir().equals(scratch.getFilesDir()) ||
                    !app.getDatabasePath("legado.db").equals(scratch.getDatabasePath("legado.db"))) {
                throw new IllegalStateException("appCtx escaped scratch storage");
            }
            File prefs = new File(getTargetContext().getApplicationInfo().dataDir, "shared_prefs");
            JSONObject probe = scratch.seedProbePreferences(app, prefs, "liber_replace_selected_probe");
            if (!probe.getBoolean("registered") || !probe.getBoolean("committed") ||
                    !probe.getBoolean("scopedFile") || probe.getBoolean("installationFile")) {
                throw new IllegalStateException("scratch preference probe failed");
            }
            report.put("isolation", new JSONObject().put("verified", true)
                .put("files", app.getFilesDir().toString())
                .put("database", app.getDatabasePath("legado.db").toString())
                .put("preferencesPrefix", PREFIX).put("preferenceProbe", probe)
                .put("scratchRoot", scratch.root.toString())
                .put("application", app.getClass().getName()));
            report.put("hostInitialization", HostRuntimeInit.initialize(loader,
                corpus.getJSONObject("hostInitialization")));
            Class<?> bookClass = loader.loadClass("io.legado.app.data.entities.Book");
            Class<?> chapterClass = loader.loadClass("io.legado.app.data.entities.BookChapter");
            Class<?> replaceBook = loader.loadClass("io.legado.app.data.entities.ReplaceBook");
            Class<?> processorClass = loader.loadClass("io.legado.app.help.book.ContentProcessor");
            titleMethod = chapterClass.getMethod("getDisplayTitle", List.class, boolean.class,
                boolean.class, replaceBook);
            contentMethod = processorClass.getMethod("getContent", bookClass, chapterClass,
                String.class, boolean.class, boolean.class, boolean.class, boolean.class,
                Boolean.class, List.class, List.class);
            report.put("entryPoints", new JSONObject().put("getDisplayTitleArity", 4)
                .put("getDisplayTitle", titleMethod.toString()).put("getContentArity", 10)
                .put("getContent", contentMethod.toString()));
            database = loader.loadClass("io.legado.app.data.AppDatabaseKt").getMethod("getAppDb").invoke(null);
            Object dao = call(database, "getReplaceRuleDao");
            Object config = singleton("io.legado.app.help.config.AppConfig");
            Object readConfig = singleton("io.legado.app.help.config.ReadBookConfig");
            Object backupPath = call(config, "getBackupPath");
            if (backupPath != null) throw new IllegalStateException("scratch backup path is not absent");
            report.put("settingsBefore", new JSONObject()
                .put("paragraphIndent", call(readConfig, "getParagraphIndent"))
                .put("adaptSpecialStyle", call(config, "getAdaptSpecialStyle"))
                .put("chineseConverterType", call(config, "getChineseConverterType"))
                .put("replaceEnableDefault", call(config, "getReplaceEnableDefault"))
                .put("backupPath", JSONObject.NULL));
            call(readConfig, "setParagraphIndent", "　　");
            Object paragraphIndent = call(readConfig, "getParagraphIndent");
            if (!"　　".equals(paragraphIndent)) throw new IllegalStateException("paragraph indent did not bind");
            report.put("paragraphIndent", paragraphIndent);
            setupJobOwner();
            if (!children().isEmpty()) throw new IllegalStateException("DEFAULT job has pre-existing children");
            terminalProved = true;
            report.put("terminalOwner", new JSONObject().put("scope", "Coroutine.DEFAULT")
                .put("rootActive", true).put("rootCompleted", false).put("baselineChildren", 0)
                .put("childrenMethod", getChildren.toString()).put("completionMethod", isCompleted.toString()));
            JSONArray rows = new JSONArray(); report.put("rows", rows);
            JSONArray cases = corpus.getJSONArray("cases");
            JSONArray partitionIds = new JSONArray();
            for (int i = 0; i < cases.length(); i++) {
                String id = cases.getJSONObject(i).getString("id");
                if (!"timeout".equals(id)) partitionIds.put(id);
            }
            report.put("partition", new JSONObject().put("role", "reader-non-timeout")
                .put("caseIds", partitionIds));
            for (int i = 0; i < cases.length(); i++) {
                JSONObject input = cases.getJSONObject(i);
                if ("timeout".equals(input.getString("id"))) continue;
                terminalProved = false;
                JSONObject row = new JSONObject().put("id", input.getString("id")); rows.put(row);
                long started = System.nanoTime();
                try {
                    if (!children().isEmpty()) throw new IllegalStateException("DEFAULT job was not empty before row");
                    readerCalls = new JSONArray();
                    row.put("readerCalls", readerCalls);
                    runRow(input, row, dao, config);
                    row.put("terminal", awaitQuiescence());
                    terminalProved = true;
                    row.put("status", "observed");
                } catch (Throwable error) {
                    row.put("status", "error").put("error", describe(error)); throw error;
                } finally { row.put("elapsedMillis", (System.nanoTime() - started) / 1000000); }
            }
            ok = true;
        } catch (Throwable error) {
            if (scratch != null) scratch.refuseWaiters(describe(error));
            try { report.put("failure", describe(error)); } catch (Exception ignored) { }
        } finally {
            boolean closed = false;
            try {
                if (database != null && terminalProved) { call(database, "close"); closed = true; }
                JSONObject cleanup = new JSONObject().put("databaseClosed", closed)
                    .put("terminalProved", terminalProved)
                    .put("activityLaunchAttempts", GuardedReaderApplication.launchAttempts())
                    .put("scratchRemoved", false).put("scratchRetained", scratch != null && scratch.root.exists());
                // Failure keeps owned residue for controller inspection and recovery.
                if (ok && closed && scratch.isBound()) {
                    JSONArray removed = new JSONArray(); boolean preferencesRemoved = true;
                    Set<String> registeredPreferences = scratch.ownedPreferences();
                    cleanup.put("registeredPreferences", new JSONArray(registeredPreferences));
                    for (String name : registeredPreferences) {
                        boolean deleted = scratch.deletePreference(name);
                        preferencesRemoved &= deleted;
                        removed.put(new JSONObject().put("name", name).put("ok", deleted));
                    }
                    boolean rootRemoved = preferencesRemoved && scratch.removeRoot();
                    cleanup.put("preferencesRemoved", removed).put("scratchRemoved", rootRemoved)
                        .put("scratchRetained", !rootRemoved && scratch.root.exists());
                    ok = rootRemoved && preferencesRemoved;
                } else ok = false;
                report.put("cleanup", cleanup);
            } catch (Throwable error) {
                ok = false;
                try { report.put("cleanupFailure", describe(error)); } catch (Exception ignored) { }
            }
            Bundle status = new Bundle();
            status.putString("stream", "READER_ORACLE_BASE64=" + Base64.encodeToString(
                report.toString().getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP) + "\n");
            finish(ok ? -1 : 1, status);
        }
    }

    private void setupJobOwner() throws Exception {
        Class<?> owner = loader.loadClass("io.legado.app.help.coroutine.Coroutine");
        Field field = owner.getDeclaredField("DEFAULT"); field.setAccessible(true);
        Object scope = field.get(null);
        Class<?> scopeType = loader.loadClass("kotlinx.coroutines.CoroutineScope");
        Object context = scopeType.getMethod("getCoroutineContext").invoke(scope);
        Class<?> contextType = loader.loadClass("kotlin.coroutines.CoroutineContext");
        Class<?> keyType = loader.loadClass("kotlin.coroutines.CoroutineContext$Key");
        Class<?> jobType = loader.loadClass("kotlinx.coroutines.Job");
        Object key = jobType.getField("Key").get(null);
        rootJob = contextType.getMethod("get", keyType).invoke(context, key);
        if (rootJob == null || !jobType.isInstance(rootJob)) throw new IllegalStateException("DEFAULT Job absent");
        getChildren = jobType.getMethod("getChildren");
        isCompleted = jobType.getMethod("isCompleted");
        isActive = jobType.getMethod("isActive");
        if (!(Boolean) isActive.invoke(rootJob) || (Boolean) isCompleted.invoke(rootJob)) {
            throw new IllegalStateException("DEFAULT Job is not an active owner");
        }
        sequenceIterator = loader.loadClass("kotlin.sequences.Sequence").getMethod("iterator");
    }

    private Set<Object> children() throws Exception {
        if (!(Boolean) isActive.invoke(rootJob) || (Boolean) isCompleted.invoke(rootJob)) {
            throw new IllegalStateException("DEFAULT Job stopped being an active owner");
        }
        Object sequence = getChildren.invoke(rootJob);
        Iterator<?> iterator = (Iterator<?>) sequenceIterator.invoke(sequence);
        Set<Object> result = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        while (iterator.hasNext()) result.add(iterator.next());
        return result;
    }

    private JSONObject awaitQuiescence() throws Exception {
        Set<Object> seen = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        long deadline = android.os.SystemClock.elapsedRealtime() + 10000;
        while (true) {
            seen.addAll(children());
            boolean completed = true;
            for (Object job : seen) completed &= (Boolean) isCompleted.invoke(job);
            if (GuardedReaderApplication.launchAttempts() != 0)
                throw new IllegalStateException("reader attempted an activity launch");
            if (completed && children().isEmpty()) return new JSONObject()
                .put("owner", "Coroutine.DEFAULT Job").put("observedChildren", seen.size())
                .put("allCompleted", true).put("rootEmpty", true).put("launchAttempts", 0);
            if (android.os.SystemClock.elapsedRealtime() >= deadline)
                throw new IllegalStateException("DEFAULT Job did not reach quiescence");
            Thread.sleep(20);
        }
    }

    @Override protected Object effectiveRulesValue(JSONArray rules) {
        return rules == null ? JSONObject.NULL : rules;
    }

    @Override protected Object displayTitle(Object chapter, List<?> rules) throws Exception {
        if (!children().isEmpty()) throw new IllegalStateException("job active before title read");
        Object value = titleMethod.invoke(chapter, rules, true, true, null);
        readerCalls.put(awaitQuiescence().put("method", "getDisplayTitle"));
        return value;
    }

    @Override protected Object content(Object processor, Object book, Object chapter, String raw) throws Exception {
        if (!children().isEmpty()) throw new IllegalStateException("job active before content read");
        Object value = contentMethod.invoke(processor, book, chapter, raw, false, true, true, true,
            null, null, null);
        readerCalls.put(awaitQuiescence().put("method", "getContent"));
        return value;
    }
}
