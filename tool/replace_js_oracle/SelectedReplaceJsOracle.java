package io.liber.oracle.nested;

import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Base64;
import io.liber.oracle.replacejs.ReplaceJsOracle;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Fixed-role selected entry. The legacy oracle remains the default entry. */
public final class SelectedReplaceJsOracle extends ReplaceJsOracle {
    private static final String BASELINE = "a7d37f1707a70a459ad708f4fe79341d1e42d716";
    private static final String APK = "593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5";
    private static final String TARGET = "com.legado.app.debug";
    private static final String PACKAGE = "io.liber.oracle.replacejs.selected";
    private static final String PREFIX = "liber_replace_js_selected_";
    private static final String[] IDS = {"js-returned-text", "js-title-scope", "js-match-and-capture",
        "js-binding-surface", "js-ordering-with-literal", "js-literal-branch-prefix", "js-disabled",
        "js-error", "backup-rule-1", "backup-rule-2", "backup-rule-3", "backup-rule-4", "js-timeout"};
    private StateSessionOracle.ScratchContext scratch;
    private String role;
    private Method titleMethod, contentMethod, childrenMethod, isActive, isCompleted, iteratorMethod;
    private Object rootJob;
    private boolean terminalProved;
    private JSONArray calls;

    @Override public Application newApplication(ClassLoader cl, String name, Context context)
            throws InstantiationException, IllegalAccessException, ClassNotFoundException {
        scratch = new StateSessionOracle.ScratchContext(context, "liber-replace-js-selected", PREFIX, true);
        // No provider is allowed to initialize before the selected scratch suffix is set.
        SelectedWebViewContainment.setSuffix();
        return Instrumentation.newApplication(GuardedReaderApplication.class, scratch);
    }

    @Override public boolean onException(Object object, Throwable error) {
        return (scratch != null && scratch.handleShortcutException(object, error)) || super.onException(object, error);
    }

    @Override public void onCreate(Bundle args) {
        startInstrumentation(args);
        role = args == null ? null : args.getString("role");
        if (!"main12".equals(role) && !"timeout".equals(role)) {
            if (scratch != null) scratch.refuseWaiters("invalid fixed role");
            Bundle result = new Bundle();
            result.putString("stream", "REPLACE_JS: invalid fixed role\n");
            finish(1, result);
            return;
        }
        // Do not call the legacy onCreate: that entry starts its own corpus.
        new Handler(Looper.getMainLooper()).post(() -> new Thread(this::runSelected, "selected-replace-js").start());
    }

    private static byte[] readAll(InputStream input) throws Exception {
        try (InputStream in = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192]; int n;
            while ((n = in.read(buffer)) != -1) out.write(buffer, 0, n);
            return out.toByteArray();
        }
    }
    private static String fileHash(String path) throws Exception { return hash(readAll(new FileInputStream(path))); }
    private static String processStartTicks() throws Exception {
        String stat = new String(readAll(new FileInputStream("/proc/self/stat")), StandardCharsets.UTF_8);
        int end = stat.lastIndexOf(')');
        if (end < 0) throw new IllegalStateException("process stat malformed");
        String[] fields = stat.substring(end + 1).trim().split("\\s+");
        if (fields.length <= 19 || !fields[19].matches("[0-9]+")) throw new IllegalStateException("process start time absent");
        return fields[19];
    }

    private void runSelected() {
        JSONObject report = new JSONObject(); Object database = null; boolean ok = false;
        try {
            byte[] bytes = readAll(getContext().getAssets().open("fixtures-selected.json"));
            JSONObject corpus = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
            JSONArray cases = corpus.getJSONArray("cases");
            if (!"REPLACE-JS-01".equals(corpus.getString("fixtureId")) || corpus.getInt("corpusVersion") != 1 ||
                !BASELINE.equals(corpus.getString("baselineCommit")) || cases.length() != IDS.length ||
                !TARGET.equals(getTargetContext().getPackageName()) || !PACKAGE.equals(getContext().getPackageName()) ||
                !TARGET.equals(corpus.getJSONObject("target").getString("package")) ||
                !APK.equals(corpus.getJSONObject("target").getString("apkSha256"))) throw new IllegalStateException("identity differs");
            for (int i = 0; i < IDS.length; i++) if (!IDS[i].equals(cases.getJSONObject(i).getString("id")))
                throw new IllegalStateException("full corpus identity/order differs");
            String targetHash = fileHash(getTargetContext().getApplicationInfo().sourceDir);
            if (!APK.equals(targetHash)) throw new IllegalStateException("target APK differs");
            byte[] provenanceBytes = readAll(getContext().getAssets().open("provenance.json"));
            JSONObject provenance = new JSONObject(new String(provenanceBytes, StandardCharsets.UTF_8).replace("\uFEFF", ""));
            String fixtureHash = hash(bytes);
            if (!BASELINE.equals(provenance.getString("baselineCommit")) ||
                !fixtureHash.equals(provenance.getString("corpusAssetSha256"))) throw new IllegalStateException("corpus provenance differs");
            String runId = UUID.randomUUID().toString();
            JSONObject identity = new JSONObject().put("fixtureId", "REPLACE-JS-01").put("corpusVersion", 1)
                .put("role", role).put("runId", runId).put("pid", android.os.Process.myPid())
                .put("processStartTicks", processStartTicks())
                .put("corpusSha256Lf", fixtureHash).put("corpusAssetSha256", fixtureHash)
                .put("targetPackage", TARGET).put("targetApkSha256", targetHash)
                .put("harnessPackage", PACKAGE).put("harnessApkSha256", fileHash(getContext().getApplicationInfo().sourceDir))
                .put("provenanceAssetSha256", hash(provenanceBytes));
            report.put("fixtureId", "REPLACE-JS-01").put("corpusVersion", 1).put("baselineCommit", BASELINE)
                .put("fixtureSha256", fixtureHash).put("boundary", corpus.getString("comparisonBoundary"))
                .put("fingerprint", Build.FINGERPRINT).put("role", role).put("pid", android.os.Process.myPid())
                .put("identity", identity).put("provenance", provenance).put("startupContainment", scratch.shortcutReceipt());
            scratch.bindRun(identity);
            File roleOwner = new File(scratch.root, "role-owner.json");
            if (!roleOwner.createNewFile()) throw new IllegalStateException("role owner already exists");
            try (FileOutputStream output = new FileOutputStream(roleOwner)) {
                output.write(identity.toString().getBytes(StandardCharsets.UTF_8));
                output.getFD().sync();
            }
            JSONObject ownerIdentity = new JSONObject(new String(readAll(new FileInputStream(roleOwner)), StandardCharsets.UTF_8));
            if (!identity.toString().equals(ownerIdentity.toString())) throw new IllegalStateException("role owner identity differs");
            report.put("roleOwner", roleOwner.toString()).put("roleOwnerIdentity", ownerIdentity);
            loader = getTargetContext().getClassLoader();
            Context app = (Context) loader.loadClass("splitties.init.AppCtxKt").getMethod("getAppCtx").invoke(null);
            if (!(app instanceof GuardedReaderApplication) || !app.getFilesDir().equals(scratch.getFilesDir()) ||
                !app.getDatabasePath("legado.db").equals(scratch.getDatabasePath("legado.db")) ||
                !app.getExternalCacheDir().equals(scratch.getExternalCacheDir())) throw new IllegalStateException("scratch routing differs");
            JSONObject probe = scratch.seedProbePreferences(app, new File(getTargetContext().getApplicationInfo().dataDir, "shared_prefs"), "liber_replace_js_probe");
            if (!probe.getBoolean("registered") || !probe.getBoolean("committed") || !probe.getBoolean("scopedFile") || probe.getBoolean("installationFile"))
                throw new IllegalStateException("scratch preference probe failed");
            report.put("isolation", new JSONObject().put("verified", true).put("application", app.getClass().getName())
                .put("scratchRoot", scratch.root.toString()).put("files", app.getFilesDir().toString())
                .put("database", app.getDatabasePath("legado.db").toString()).put("externalCache", app.getExternalCacheDir().toString())
                .put("preferencesPrefix", PREFIX).put("preferenceProbe", probe));
            report.put("webViewContainment", SelectedWebViewContainment.verify(app, getTargetContext(), scratch.root));
            report.put("hostInitialization", HostRuntimeInit.initialize(loader, corpus.getJSONObject("hostInitialization")));
            Class<?> book = loader.loadClass("io.legado.app.data.entities.Book");
            Class<?> chapter = loader.loadClass("io.legado.app.data.entities.BookChapter");
            Class<?> replaceBook = loader.loadClass("io.legado.app.data.entities.ReplaceBook");
            Class<?> processor = loader.loadClass("io.legado.app.help.book.ContentProcessor");
            titleMethod = chapter.getMethod("getDisplayTitle", List.class, boolean.class, boolean.class, replaceBook);
            contentMethod = processor.getMethod("getContent", book, chapter, String.class, boolean.class, boolean.class,
                boolean.class, boolean.class, Boolean.class, List.class, List.class);
            Class<?> bookContent = loader.loadClass("io.legado.app.help.book.BookContent");
            Method replaceBookMethod = book.getMethod("toReplaceBook");
            if (titleMethod.getReturnType() != String.class || contentMethod.getReturnType() != bookContent ||
                replaceBookMethod.getReturnType() != replaceBook) throw new IllegalStateException("selected return ABI differs");
            Class<?> rule = loader.loadClass("io.legado.app.data.entities.ReplaceRule");
            report.put("entryPoints", new JSONObject().put("getDisplayTitle", titleMethod.toString()).put("getContent", contentMethod.toString())
                .put("toReplaceBook", replaceBookMethod.toString()).put("bookConstructor", book.getConstructor().toString())
                .put("chapterConstructor", chapter.getConstructor().toString()).put("ruleConstructor", rule.getConstructor().toString())
                .put("textList", bookContent.getMethod("getTextList").toString())
                .put("sameTitleRemoved", bookContent.getMethod("getSameTitleRemoved").toString())
                .put("effectiveRules", bookContent.getMethod("getEffectiveReplaceRules").toString()));
            database = loader.loadClass("io.legado.app.data.AppDatabaseKt").getMethod("getAppDb").invoke(null);
            Object dao = call(database, "getReplaceRuleDao");
            Object config = singleton("io.legado.app.help.config.AppConfig");
            Object readConfig = singleton("io.legado.app.help.config.ReadBookConfig");
            if (call(config, "getBackupPath") != null) throw new IllegalStateException("scratch backup path is not absent");
            report.put("settingsBefore", new JSONObject().put("backupPath", JSONObject.NULL)
                .put("paragraphIndent", call(readConfig, "getParagraphIndent"))
                .put("adaptSpecialStyle", call(config, "getAdaptSpecialStyle"))
                .put("chineseConverterType", call(config, "getChineseConverterType"))
                .put("replaceEnableDefault", call(config, "getReplaceEnableDefault")));
            call(readConfig, "setParagraphIndent", "　　");
            if (!"　　".equals(call(readConfig, "getParagraphIndent"))) throw new IllegalStateException("indent differs");
            setupJobOwner();
            if (!children().isEmpty()) throw new IllegalStateException("DEFAULT job has existing children");
            terminalProved = true;
            report.put("terminalOwner", new JSONObject().put("scope", "Coroutine.DEFAULT").put("rootActive", true)
                .put("rootCompleted", false).put("baselineChildren", 0).put("childrenMethod", childrenMethod.toString())
                .put("completionMethod", isCompleted.toString()));
            JSONArray rows = new JSONArray(), ids = new JSONArray(); report.put("rows", rows);
            int start = "main12".equals(role) ? 0 : 12, end = "main12".equals(role) ? 12 : 13;
            for (int i = start; i < end; i++) ids.put(IDS[i]);
            report.put("partition", new JSONObject().put("role", role).put("caseIds", ids));
            for (int i = start; i < end; i++) {
                terminalProved = false; JSONObject row = new JSONObject().put("id", IDS[i]); rows.put(row);
                long started = System.nanoTime();
                try {
                    if (!children().isEmpty()) throw new IllegalStateException("job active before row");
                    calls = new JSONArray(); row.put("readerCalls", calls);
                    runRow(cases.getJSONObject(i), row, dao, config);
                    row.put("terminal", awaitQuiescence()); terminalProved = true; row.put("status", "observed");
                } catch (Throwable error) { row.put("status", "error").put("error", describe(error)); throw error; }
                finally { row.put("elapsedMillis", (System.nanoTime() - started) / 1000000); }
            }
            ok = true;
        } catch (Throwable error) {
            if (scratch != null) scratch.refuseWaiters(describe(error));
            try { report.put("failure", describe(error)); } catch (Exception ignored) { }
        } finally {
            try {
                boolean closed = false;
                if (database != null && terminalProved) { call(database, "close"); closed = true; }
                JSONObject cleanup = new JSONObject().put("databaseClosed", closed).put("terminalProved", terminalProved)
                    .put("activityLaunchAttempts", GuardedReaderApplication.launchAttempts())
                    .put("scratchRemoved", false).put("scratchRetained", scratch != null && scratch.root.exists());
                // WebView may still own background work. Host cleanup is only permitted
                // after the exact owned process is proven terminated and owners rechecked.
                if (ok && closed && terminalProved && scratch.isBound() && scratch.root.isDirectory() &&
                        GuardedReaderApplication.launchAttempts() == 0) {
                    cleanup.put("registeredPreferences", new JSONArray(scratch.ownedPreferences()));
                    cleanup.put("hostCleanup", "required-after-owned-process-termination");
                } else ok = false;
                report.put("cleanup", cleanup);
            } catch (Throwable error) { ok = false; try { report.put("cleanupFailure", describe(error)); } catch (Exception ignored) { } }
            Bundle status = new Bundle();
            status.putString("stream", "REPLACE_JS_ORACLE_BASE64=" + Base64.encodeToString(report.toString().getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP) + "\n");
            finish(ok ? -1 : 1, status);
        }
    }

    private void setupJobOwner() throws Exception {
        Field field = loader.loadClass("io.legado.app.help.coroutine.Coroutine").getDeclaredField("DEFAULT"); field.setAccessible(true);
        Object scope = field.get(null);
        Object context = loader.loadClass("kotlinx.coroutines.CoroutineScope").getMethod("getCoroutineContext").invoke(scope);
        Class<?> job = loader.loadClass("kotlinx.coroutines.Job");
        rootJob = loader.loadClass("kotlin.coroutines.CoroutineContext").getMethod("get", loader.loadClass("kotlin.coroutines.CoroutineContext$Key")).invoke(context, job.getField("Key").get(null));
        if (rootJob == null || !job.isInstance(rootJob)) throw new IllegalStateException("DEFAULT Job absent");
        childrenMethod = job.getMethod("getChildren"); isActive = job.getMethod("isActive"); isCompleted = job.getMethod("isCompleted");
        iteratorMethod = loader.loadClass("kotlin.sequences.Sequence").getMethod("iterator");
        if (!(Boolean)isActive.invoke(rootJob) || (Boolean)isCompleted.invoke(rootJob)) throw new IllegalStateException("DEFAULT Job inactive");
    }
    private Set<Object> children() throws Exception {
        if (!(Boolean)isActive.invoke(rootJob) || (Boolean)isCompleted.invoke(rootJob)) throw new IllegalStateException("DEFAULT Job inactive");
        Iterator<?> iterator = (Iterator<?>)iteratorMethod.invoke(childrenMethod.invoke(rootJob));
        Set<Object> result = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        while (iterator.hasNext()) result.add(iterator.next()); return result;
    }
    private JSONObject awaitQuiescence() throws Exception {
        Set<Object> seen = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        long deadline = SystemClock.elapsedRealtime() + 10000;
        while (true) {
            seen.addAll(children()); boolean completed = true;
            for (Object job : seen) completed &= (Boolean)isCompleted.invoke(job);
            if (GuardedReaderApplication.launchAttempts() != 0) throw new IllegalStateException("reader attempted an activity launch");
            if (completed && children().isEmpty()) return new JSONObject().put("owner", "Coroutine.DEFAULT Job")
                .put("observedChildren", seen.size()).put("allCompleted", true).put("rootEmpty", true).put("launchAttempts", 0);
            if (SystemClock.elapsedRealtime() >= deadline) throw new IllegalStateException("DEFAULT Job did not reach quiescence");
            Thread.sleep(20);
        }
    }
    @Override protected Object displayTitle(Object book, Object chapter, List<?> rules) throws Exception {
        if (!children().isEmpty()) throw new IllegalStateException("job active before title");
        Object value = titleMethod.invoke(chapter, rules, true, true, call(book, "toReplaceBook"));
        calls.put(awaitQuiescence().put("method", "getDisplayTitle")); return value;
    }
    @Override protected Object content(Object processor, Object book, Object chapter, String raw) throws Exception {
        if (!children().isEmpty()) throw new IllegalStateException("job active before content");
        Object value = contentMethod.invoke(processor, book, chapter, raw, false, true, true, true, null, null, null);
        calls.put(awaitQuiescence().put("method", "getContent")); return value;
    }
    @Override protected Object effectiveRulesValue(JSONArray rules) { return rules == null ? JSONObject.NULL : rules; }
    @Override protected void recordTimeout(JSONObject out, JSONArray disabled) throws Exception {
        out.put("restartObservation", "not-observed");
    }
}
