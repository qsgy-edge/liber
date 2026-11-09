package io.liber.oracle.fields;

import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import io.liber.oracle.nested.StateSessionOracle;

/**
 * The frozen side of the FIELDS-01 corpus (ticket #41): drives
 * {@code io.legado.app.model.webBook.WebBook}'s four suspend entry points
 * against the installed, hash-pinned {@code io.legado.app.debug} and observes
 * {@code io.legado.app.data.entities.BookSource.getCheckKeyword}. It serves
 * {@code tool/result_field_oracle/fixtures.json} on the port the corpus names,
 * inside this process. No Legado class is rebuilt; every entry point is reached
 * by reflection.
 *
 * <p>This harness is disposable and separate from {@code tool/nested_oracle}: it
 * has its own package id ({@code io.liber.oracle.fields}), its own corpus asset
 * and its own report ({@code field-oracle.json}). It does not touch SLICE-01's
 * corpus, golden or comparison.
 *
 * <p>The work is posted to the main looper because the target application is
 * created after {@link #onCreate}, and the frozen HTTP stack has to be past that
 * point. It then runs on its own thread, because the four suspend calls are
 * driven with {@code kotlinx.coroutines.runBlocking}.
 *
 * <p>The report is rewritten after every corpus case, so a host that freezes the
 * process a few seconds in (MIUI does) keeps the cases that already finished.
 */
public final class FieldOracle extends Instrumentation {

    private static final String ASSET = "field-fixtures.json";
    private static final String REPORT = "field-oracle.json";
    private static final String FIELDS_01 = "FIELDS-01";
    private static final String FIELDS_02 = "FIELDS-02";
    private static final String SELECTED_BASELINE = "a7d37f1707a70a459ad708f4fe79341d1e42d716";
    private static final String SELECTED_TARGET = "com.legado.app.debug";
    private static final String SELECTED_APK = "593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5";
    private static final String SCRATCH_ROOT_NAME = "liber-fields-02";
    private static final String PREFERENCE_PREFIX = "liber_fields_02_";
    /** The one terminal whose case also saves a chapter and refreshes the TOC. */
    private static final String TITLE_LIFECYCLE_TERMINAL = "four-stage-refresh";
    private static final String TOC_COUNT_WORDS = "tocCountWords";
    /** Distinct raw variable text seeded on the two lifecycle chapters. */
    private static final String[] SEED_VARIABLES = {"toc-a", "toc-b"};
    private static final int LIFECYCLE_CHAPTERS = 2;

    private final JSONArray requests = new JSONArray();
    private final JSONArray unmatched = new JSONArray();
    private final JSONArray serverErrors = new JSONArray();
    private final JSONArray stageTrace = new JSONArray();
    private final JSONObject cases = new JSONObject();
    private final JSONArray caseRecords = new JSONArray();
    private final JSONObject isolation = new JSONObject();
    private boolean newFamily;
    private boolean selectedReference;
    private Object rootJob;
    private Method jobChildren, jobCompleted, jobActive, sequenceIterator;
    private Object selectedDatabase;
    private boolean terminalProved;
    private StateSessionOracle.ScratchContext scratch;
    private final JSONObject selectedEntryPoints = new JSONObject();
    private final JSONObject caseFailures = new JSONObject();
    private final JSONObject checkKeyword = new JSONObject();
    private final JSONObject cleanup = new JSONObject();
    private JSONObject fields02Observation;
    private int fields02RequestStart;
    private final AtomicReference<String> stage = new AtomicReference<>("setup");
    private final java.util.concurrent.atomic.AtomicBoolean finished =
        new java.util.concurrent.atomic.AtomicBoolean();

    private JSONObject corpus;
    private FieldReplay replay;
    private JSONObject report;
    private File output;

    @Override
    public Application newApplication(ClassLoader cl, String name, Context context)
            throws InstantiationException, IllegalAccessException, ClassNotFoundException {
        // Selection is decided before either the original target Application or
        // the scratch Application exists. The argument context belongs to the
        // target package; the selected corpus asset lives in the instrumentation
        // package. Any unreadable, malformed or unsupported selection refuses
        // here instead of falling back to the original target startup.
        Context harnessContext = getContext();
        if (harnessContext == null) {
            throw new IllegalStateException("instrumentation context unavailable for selection");
        }
        JSONObject selection;
        try {
            selection = readAssetObject(harnessContext, ASSET);
        } catch (Throwable error) {
            throw new IllegalStateException("cannot read FIELDS asset selection", error);
        }
        String fixtureId = selection.optString("fixtureId", "");
        if (FIELDS_02.equals(fixtureId)) {
            Object version = selection.opt("corpusVersion");
            if (!(version instanceof Integer) || ((Integer) version) != 1) {
                throw new IllegalStateException("unsupported FIELDS-02 corpusVersion");
            }
            validateFields02Selection(selection);
            newFamily = true;
            selectedReference = SELECTED_BASELINE.equals(selection.optString("baselineCommit"));
            if (selectedReference) {
                JSONObject target = selection.optJSONObject("target");
                if (target == null || !SELECTED_TARGET.equals(target.optString("package"))
                        || !SELECTED_APK.equals(target.optString("apkSha256"))) {
                    throw new IllegalStateException("selected FIELDS target differs");
                }
                try {
                    Class<?> bridge = Class.forName("io.liber.oracle.nested.SelectedFieldHostBridge");
                    scratch = (StateSessionOracle.ScratchContext) bridge.getMethod("guardedScratch",
                        Context.class, String.class, String.class).invoke(null, context,
                            SCRATCH_ROOT_NAME, PREFERENCE_PREFIX);
                    Class<? extends Application> application = Class.forName(
                        "io.liber.oracle.nested.GuardedReaderApplication").asSubclass(Application.class);
                    return Instrumentation.newApplication(application, scratch);
                } catch (ReflectiveOperationException error) {
                    throw new IllegalStateException("selected FIELDS host bridge failed", error);
                }
            }
            scratch = new StateSessionOracle.ScratchContext(
                context, SCRATCH_ROOT_NAME, PREFERENCE_PREFIX);
            // HTTP_BOUNDARY-01's measured storage-only Application: frozen
            // App.onCreate never runs, and the target app's files, database and
            // prefs route under the bound scratch root.
            return super.newApplication(cl, Application.class.getName(), scratch);
        }
        if (FIELDS_01.equals(fixtureId)) {
            newFamily = false;
            return super.newApplication(cl, name, context);
        }
        throw new IllegalStateException("unsupported FIELDS fixtureId: " + fixtureId);
    }

    @Override
    public boolean onException(Object object, Throwable error) {
        if (selectedReference && scratch != null) {
            try {
                Class<?> bridge = Class.forName("io.liber.oracle.nested.SelectedFieldHostBridge");
                boolean handled = (Boolean) bridge.getMethod("handleShortcutException",
                    StateSessionOracle.ScratchContext.class, Object.class, Throwable.class)
                    .invoke(null, scratch, object, error);
                if (handled) return true;
            } catch (ReflectiveOperationException bridgeError) {
                throw new IllegalStateException("selected shortcut guard failed", bridgeError);
            }
        }
        return super.onException(object, error);
    }

    private static boolean declaresRuleField(JSONObject source, String ruleName, String field) {
        JSONObject rules = source.optJSONObject(ruleName);
        return rules != null && rules.has(field);
    }

    private static void validateFields02Selection(JSONObject selection) {
        JSONArray declared = selection.optJSONArray("cases");
        if (declared == null || declared.length() == 0) {
            throw new IllegalStateException("FIELDS-02 selection has no cases");
        }
        java.util.Set<String> ids = new java.util.HashSet<>();
        for (int index = 0; index < declared.length(); index++) {
            JSONObject entry = declared.optJSONObject(index);
            if (entry == null) {
                throw new IllegalStateException("FIELDS-02 case is not an object");
            }
            Object idValue = entry.opt("id");
            if (!(idValue instanceof String) || ((String) idValue).isEmpty()
                    || !ids.add((String) idValue)) {
                throw new IllegalStateException("FIELDS-02 case id is empty, repeated or not a string");
            }
            if (!(entry.opt("keyword") instanceof String)) {
                throw new IllegalStateException("FIELDS-02 case keyword is not a string");
            }
            if (!(entry.opt("source") instanceof JSONObject)) {
                throw new IllegalStateException("FIELDS-02 case source is not an object");
            }
            Object terminalValue = entry.has("terminal") ? entry.opt("terminal") : "four-stage";
            if (!(terminalValue instanceof String)
                    || (!"four-stage".equals(terminalValue)
                        && !"search-empty".equals(terminalValue)
                        && !TITLE_LIFECYCLE_TERMINAL.equals(terminalValue))) {
                throw new IllegalStateException("FIELDS-02 case terminal is unsupported");
            }
        }
    }

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        log("onCreate");
        new Handler(Looper.getMainLooper()).post(() -> {
            log("main looper reached; starting the worker thread");
            new Thread(this::run, "fields-oracle").start();
        });
        startWatchdog();
    }

    /**
     * An instrumentation that never finishes reports nothing on the host, so a
     * stalled case has to surface as a result rather than as silence.
     */
    private void startWatchdog() {
        Thread watchdog = new Thread(() -> {
            try {
                Thread.sleep(180000);
            } catch (InterruptedException interrupted) {
                return;
            }
            if (finished.compareAndSet(false, true)) {
                log("watchdog: no result after 180s; stage=" + stage.get());
                Bundle status = new Bundle();
                status.putString("stream", "Fields oracle timed out in stage " + stage.get()
                    + " after " + requests.length() + " requests\n");
                finish(1, status);
            }
        }, "fields-oracle-watchdog");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    private void log(String message) {
        Log.i("FieldOracle", message);
    }

    private void run() {
        Bundle status = new Bundle();
        try {
            log("harness start");
            byte[] asset = readAssetBytes(ASSET);
            corpus = new JSONObject(new String(asset, StandardCharsets.UTF_8));
            log("corpus loaded: " + corpus.getString("fixtureId"));
            if (newFamily) {
                bindScratch(asset);
                output = new File(scratch.root, REPORT);
            } else {
                output = new File(getTargetContext().getExternalFilesDir(null), REPORT);
            }
            report = new JSONObject()
                .put("fixtureId", corpus.getString("fixtureId"))
                .put("corpusVersion", corpus.getInt("corpusVersion"))
                .put("baselineCommit", corpus.getString("baselineCommit"))
                .put("entryPoint", corpus.getString("entryPoint"))
                .put("checkKeywordEntryPoint", corpus.optString("checkKeywordEntryPoint", ""))
                .put("platform", "android")
                .put("origin", corpus.getString("origin"))
                .put("fingerprint", Build.FINGERPRINT)
                .put("recordedAt", timestamp())
                .put("requests", requests)
                .put("unmatchedRequests", unmatched)
                .put("serverErrors", serverErrors)
                .put("stageTrace", stageTrace)
                .put("cases", newFamily ? caseRecords : cases)
                .put("caseFailures", caseFailures)
                .put("checkKeyword", checkKeyword)
                .put("cleanup", cleanup)
                .put("analysisFailure", JSONObject.NULL);
            if (selectedReference) {
                report.put("entryPoints", selectedEntryPoints);
                Class<?> bridge = Class.forName("io.liber.oracle.nested.SelectedFieldHostBridge");
                report.put("startupContainment", bridge.getMethod("shortcutReceipt",
                    StateSessionOracle.ScratchContext.class).invoke(null, scratch));
                ClassLoader loader = getTargetContext().getClassLoader();
                report.put("hostInitialization", bridge.getMethod("initialize",
                    ClassLoader.class, JSONObject.class).invoke(null,
                        loader, corpus.getJSONObject("hostInitialization")));
                selectedDatabase = loader.loadClass("io.legado.app.data.AppDatabaseKt")
                    .getMethod("getAppDb").invoke(null);
                setupSelectedJob(loader);
                if (!selectedChildren().isEmpty()) throw new IllegalStateException("DEFAULT Job already has children");
                terminalProved = true;
                report.put("terminalOwner", new JSONObject().put("scope", "Coroutine.DEFAULT")
                    .put("rootActive", true).put("rootCompleted", false)
                    .put("baselineChildren", 0).put("childrenMethod", jobChildren.toString())
                    .put("completionMethod", jobCompleted.toString()));
            }
            if (newFamily) {
                JSONObject corpusIdentity = new JSONObject()
                    .put("asset", ASSET)
                    .put("bytes", asset.length)
                    .put("sha256", sha256(asset))
                    .put("sha256Lf", sha256(lf(asset)))
                    .put("fixtureId", corpus.getString("fixtureId"))
                    .put("corpusVersion", corpus.getInt("corpusVersion"));
                report.put("corpus", corpusIdentity).put("isolation", isolation);
            }
            replay = new FieldReplay(corpus, requests, unmatched, serverErrors, stageTrace, stage, newFamily);
            replay.start();
            log("replay server bound to the corpus origin: " + corpus.getString("origin"));

            String analysisFailure = null;
            JSONArray declared = corpus.getJSONArray("cases");
            for (int index = 0; index < declared.length(); index++) {
                JSONObject entry = declared.getJSONObject(index);
                String id = entry.getString("id");
                stage.set("case:" + id);
                log("case " + id);
                if (newFamily) {
                    fields02Observation = null;
                    fields02RequestStart = requests.length();
                }
                if (selectedReference) {
                    if (!selectedChildren().isEmpty()) throw new IllegalStateException("DEFAULT Job active before case");
                    terminalProved = false;
                }
                try {
                    if (newFamily) driveCaseFields02(entry, id);
                    else driveCase(entry, id);
                    log("case " + id + " done");
                } catch (Throwable error) {
                    caseFailures.put(id, describe(error));
                    if (newFamily && fields02Observation != null) {
                        try {
                            fields02Observation.put("failure", describe(error))
                                .put("requests", requestSlice(fields02RequestStart));
                            caseRecords.put(fields02Observation);
                        } catch (Throwable ignored) {
                            // The failure is still recorded; do not fabricate a record.
                        }
                    }
                    log("case " + id + " failed: " + describe(error));
                }
                if (selectedReference) {
                    JSONObject terminal = awaitSelectedQuiescence();
                    if (fields02Observation != null) fields02Observation.put("terminalOwner", terminal);
                    terminalProved = true;
                }
                // A freeze keeps every case that already finished.
                writeReport();
            }
            if (!newFamily) observeCheckKeywords();

            // The report is written before the replay server is torn down: the
            // run's evidence must survive a host that freezes this process after
            // a few seconds (MIUI does; see the golden's manifest).
            stage.set("cleanup");
            writeReport();
            log("report written; failures=" + caseFailures.length());
            cleanup.put("openConnections", replay.openConnections());
            try {
                replay.close();
                cleanup.put("serverClosed", true);
            } catch (Throwable error) {
                cleanup.put("serverClosed", false);
                log("cleanup failed: " + describe(error));
            }
            if (selectedReference) {
                cleanup.put("openConnectionsAfterClose", replay.openConnections());
                if (!terminalProved || !cleanup.optBoolean("serverClosed") || replay.openConnections() != 0) {
                    throw new IllegalStateException("selected terminal or replay cleanup was not proven");
                }
                selectedDatabase.getClass().getMethod("close").invoke(selectedDatabase);
                cleanup.put("databaseClosed", true);
                cleanup.put("activityLaunchAttempts", selectedLaunchAttempts());
                if (selectedLaunchAttempts() != 0) throw new IllegalStateException("activity launch attempted");
            }
            if (newFamily) finishScratchCleanup();
            int recorded = newFamily ? caseRecords.length() : cases.length();
            writeReport();
            log("report rewritten with cleanup=" + cleanup);
            status.putString("stream", "Fields oracle recorded " + requests.length()
                + " requests and " + recorded + " cases"
                + (caseFailures.length() == 0 ? "" : ", " + caseFailures.length() + " failed")
                + "\n");
            finished.set(true);
            finish(caseFailures.length() == 0 ? -1 : 1, status);
        } catch (Throwable error) {
            if (scratch != null && !scratch.isBound()) scratch.refuseWaiters(describe(error));
            status.putString("stream", "Fields oracle harness error: " + describe(error) + "\n");
            log("harness error: " + describe(error));
            finished.set(true);
            finish(1, status);
        }
    }

    private int selectedLaunchAttempts() throws Exception {
        return (Integer) Class.forName("io.liber.oracle.nested.SelectedFieldHostBridge")
            .getMethod("launchAttempts").invoke(null);
    }

    private void setupSelectedJob(ClassLoader loader) throws Exception {
        java.lang.reflect.Field field = loader.loadClass("io.legado.app.help.coroutine.Coroutine")
            .getDeclaredField("DEFAULT");
        field.setAccessible(true);
        Object scope = field.get(null);
        Object context = loader.loadClass("kotlinx.coroutines.CoroutineScope")
            .getMethod("getCoroutineContext").invoke(scope);
        Class<?> job = loader.loadClass("kotlinx.coroutines.Job");
        rootJob = loader.loadClass("kotlin.coroutines.CoroutineContext")
            .getMethod("get", loader.loadClass("kotlin.coroutines.CoroutineContext$Key"))
            .invoke(context, job.getField("Key").get(null));
        if (rootJob == null || !job.isInstance(rootJob)) throw new IllegalStateException("DEFAULT Job absent");
        jobChildren = job.getMethod("getChildren");
        jobCompleted = job.getMethod("isCompleted");
        jobActive = job.getMethod("isActive");
        sequenceIterator = loader.loadClass("kotlin.sequences.Sequence").getMethod("iterator");
    }

    private java.util.Set<Object> selectedChildren() throws Exception {
        if (!(Boolean) jobActive.invoke(rootJob) || (Boolean) jobCompleted.invoke(rootJob)) {
            throw new IllegalStateException("DEFAULT Job is not active");
        }
        Iterator<?> iterator = (Iterator<?>) sequenceIterator.invoke(jobChildren.invoke(rootJob));
        java.util.Set<Object> children = java.util.Collections.newSetFromMap(
            new java.util.IdentityHashMap<Object, Boolean>());
        while (iterator.hasNext()) children.add(iterator.next());
        return children;
    }

    private JSONObject awaitSelectedQuiescence() throws Exception {
        java.util.Set<Object> seen = java.util.Collections.newSetFromMap(
            new java.util.IdentityHashMap<Object, Boolean>());
        long deadline = android.os.SystemClock.elapsedRealtime() + 10000;
        while (true) {
            seen.addAll(selectedChildren());
            boolean completed = true;
            for (Object job : seen) completed &= (Boolean) jobCompleted.invoke(job);
            if (selectedLaunchAttempts() != 0) throw new IllegalStateException("activity launch attempted");
            if (completed && selectedChildren().isEmpty()) return new JSONObject()
                .put("owner", "Coroutine.DEFAULT Job").put("observedChildren", seen.size())
                .put("allCompleted", true).put("rootEmpty", true).put("launchAttempts", 0);
            if (android.os.SystemClock.elapsedRealtime() >= deadline) {
                throw new IllegalStateException("DEFAULT Job did not reach quiescence");
            }
            Thread.sleep(20);
        }
    }

    /**
     * FIELDS-02's application/owner binding: actual target and harness APK hashes,
     * the selected asset bytes and the scratch namespace. The storage-only
     * Application is created by {@link #newApplication}.
     */
    private void bindScratch(byte[] asset) throws Exception {
        JSONObject identity = new JSONObject()
            .put("fixtureId", corpus.getString("fixtureId"))
            .put("corpusVersion", corpus.getInt("corpusVersion"))
            .put("corpusSha256Lf", sha256(lf(asset)))
            .put("targetPackage", getTargetContext().getPackageName())
            .put("targetApkSha256", sha256(new File(getTargetContext().getPackageCodePath())))
            .put("harnessPackage", getContext().getPackageName())
            .put("harnessApkSha256", sha256(new File(getContext().getPackageCodePath())));
        if (selectedReference && (!SELECTED_TARGET.equals(identity.getString("targetPackage"))
                || !SELECTED_APK.equals(identity.getString("targetApkSha256")))) {
            throw new IllegalStateException("selected installed target differs");
        }
        scratch.bind("seed", identity);
        Class<?> appCtx = getTargetContext().getClassLoader()
            .loadClass("splitties.init.AppCtxKt");
        Object app = appCtx.getMethod("getAppCtx").invoke(null);
        boolean filesRouted = ((android.content.Context) app).getFilesDir()
            .equals(scratch.getFilesDir());
        boolean databaseRouted = ((android.content.Context) app).getDatabasePath("legado.db")
            .equals(scratch.getDatabasePath("legado.db"));
        boolean deviceProtected = ((android.content.Context) app).isDeviceProtectedStorage();
        if (!filesRouted || !databaseRouted || deviceProtected
                || (selectedReference && !"io.liber.oracle.nested.GuardedReaderApplication"
                    .equals(app.getClass().getName()))) {
            throw new IllegalStateException("target app did not route through the scratch context");
        }
        File dataDir = new File(getTargetContext().getApplicationInfo().dataDir, "shared_prefs");
        JSONObject probe = scratch.seedProbePreferences(
            (android.content.Context) app, dataDir, "probe");
        if (probe.getBoolean("installationFile")
                || !probe.getBoolean("registered")
                || !probe.getBoolean("committed")
                || !probe.getBoolean("scopedFile")) {
            throw new IllegalStateException("fields preference storage is not scratch-scoped: "
                + probe);
        }
        isolation.put("bound", scratch.isBound())
            .put("targetPackage", getTargetContext().getPackageName())
            .put("targetApkSha256", identity.getString("targetApkSha256"))
            .put("harnessPackage", getContext().getPackageName())
            .put("harnessApkSha256", identity.getString("harnessApkSha256"))
            .put("corpusSha256Lf", identity.getString("corpusSha256Lf"))
            .put("appClass", app.getClass().getName())
            .put("deviceProtected", deviceProtected)
            .put("appFilesDir", ((android.content.Context) app).getFilesDir().getAbsolutePath())
            .put("scratchFilesDir", scratch.getFilesDir().getAbsolutePath())
            .put("filesRouted", filesRouted)
            .put("appDatabasePath", ((android.content.Context) app).getDatabasePath("legado.db").getAbsolutePath())
            .put("scratchDatabasePath", scratch.getDatabasePath("legado.db").getAbsolutePath())
            .put("databaseRouted", databaseRouted)
            .put("scratchRoot", scratch.root.getAbsolutePath())
            .put("rootExistedAtStart", scratch.rootExistedAtStart())
            .put("preferencesPrefix", scratch.preferencesPrefix())
            .put("preferenceProbe", probe);
    }

    /** FIELDS-02 hands the owned scratch/report to the external capture driver. */
    private void finishScratchCleanup() throws Exception {
        if (scratch == null) return;
        JSONArray owned = new JSONArray();
        boolean fenced = true;
        for (String name : scratch.ownedPreferences()) {
            owned.put(name);
            fenced &= scratch.fence(name);
        }
        cleanup.put("scratchRoot", scratch.root.getAbsolutePath())
            .put("fixtureId", "FIELDS-02")
            .put("corpusVersion", 1)
            .put("preferencesPrefix", scratch.preferencesPrefix())
            .put("rootExistedAtStart", scratch.rootExistedAtStart())
            .put("ownedPreferences", owned)
            .put("preferencesFenced", fenced)
            .put("reportPath", output.getAbsolutePath())
            .put("rootRetained", scratch.root.exists());
        boolean ownershipProven = scratch.isBound() && scratch.root.exists()
            && isolation.optBoolean("bound")
            && isolation.optBoolean("filesRouted")
            && isolation.optBoolean("databaseRouted")
            && !isolation.optBoolean("deviceProtected")
            && !isolation.optBoolean("rootExistedAtStart")
            && fenced;
        if (ownershipProven) {
            String ownerRunId = UUID.randomUUID().toString();
            scratch.writeOwnerComplete(ownerRunId);
            cleanup.put("ownerRunId", ownerRunId)
                .put("ownerComplete", true);
        } else {
            cleanup.put("ownerComplete", false);
        }
    }

    /** FIELDS-02: one actual case record; stage slots are present and nullable. */
    private void driveCaseFields02(JSONObject entry, String id) throws Exception {
        int requestStart = requests.length();
        ClassLoader loader = getTargetContext().getClassLoader();
        JSONObject sourceJson = entry.getJSONObject("source");
        boolean searchIntroDeclared = declaresRuleField(sourceJson, "ruleSearch", "intro");
        boolean infoIntroDeclared = declaresRuleField(sourceJson, "ruleBookInfo", "intro");
        String keyword = entry.getString("keyword");
        Class<?> bookSourceClass = loader.loadClass("io.legado.app.data.entities.BookSource");
        Class<?> searchBookClass = loader.loadClass("io.legado.app.data.entities.SearchBook");
        Class<?> chapterClass = loader.loadClass("io.legado.app.data.entities.BookChapter");
        Class<?> bookClass = loader.loadClass("io.legado.app.data.entities.Book");
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        Object gson = loader.loadClass("com.google.gson.Gson").getConstructor().newInstance();
        Object source = gson.getClass().getMethod("fromJson", String.class, Class.class)
            .invoke(gson, sourceJson.toString(), bookSourceClass);

        JSONObject observed = new JSONObject()
            .put("id", id)
            .put("terminal", entry.optString("terminal", "four-stage"))
            .put("search", JSONObject.NULL)
            .put("bookInfo", JSONObject.NULL)
            .put("tableOfContents", JSONObject.NULL)
            .put("chapter", JSONObject.NULL)
            .put("operations", new JSONArray())
            .put("sourceProbes", new JSONObject()
                .put("vipProbe", JSONObject.NULL)
                .put("payProbe", JSONObject.NULL));
        fields02Observation = observed;

        stage.set("search");
        log("stage search");
        int searchRequestStart = requests.length();
        int searchTraceStart = stageTrace.length();
        Object searchBooks;
        try {
            searchBooks = runSuspend(loader, continuation -> call(webBookClass, webBook,
                "searchBookAwait", 6,
                new Object[]{source, keyword, Integer.valueOf(1), null, null}, continuation));
        } catch (Exception error) {
            recordOperationError(observed, "search", searchRequestStart, searchTraceStart, error);
            throw error;
        }
        recordOperation(observed, "search", searchRequestStart, searchTraceStart);
        if (!(searchBooks instanceof List)) {
            throw new IllegalStateException("search returned " + searchBooks);
        }
        List<?> list = (List<?>) searchBooks;
        JSONArray results = new JSONArray();
        for (Object item : list) {
            JSONObject result = new JSONObject()
                .put("name", str(searchBookClass, item, "getName"))
                .put("author", str(searchBookClass, item, "getAuthor"))
                .put("bookUrl", str(searchBookClass, item, "getBookUrl"))
                .put("infoHtml", searchBookClass.getMethod("getInfoHtml").invoke(item) != null);
            if (searchIntroDeclared) {
                result.put("intro", str(searchBookClass, item, "getIntro"));
            }
            results.put(result);
        }
        observed.put("search", new JSONObject().put("results", results));
        if (list.isEmpty()) {
            if (!"search-empty".equals(observed.getString("terminal"))) {
                throw new IllegalStateException("search returned no result");
            }
            observed.put("requests", requestSlice(requestStart));
            caseRecords.put(observed);
            return;
        }
        Object book = searchBookClass.getMethod("toBook").invoke(list.get(0));

        stage.set("bookInfo");
        log("stage bookInfo");
        int infoRequestStart = requests.length();
        int infoTraceStart = stageTrace.length();
        try {
            runSuspend(loader, continuation -> call(webBookClass, webBook,
                "getBookInfoAwait", 4,
                new Object[]{source, book, Boolean.TRUE}, continuation));
        } catch (Exception error) {
            recordOperationError(observed, "bookInfo", infoRequestStart, infoTraceStart, error);
            throw error;
        }
        recordOperation(observed, "bookInfo", infoRequestStart, infoTraceStart);
        JSONObject bookInfo = new JSONObject()
            .put("name", str(bookClass, book, "getName"))
            .put("author", str(bookClass, book, "getAuthor"))
            .put("bookUrl", str(bookClass, book, "getBookUrl"))
            .put("tocUrl", str(bookClass, book, "getTocUrl"));
        if (infoIntroDeclared) {
            bookInfo.put("intro", str(bookClass, book, "getIntro"));
        }
        observed.put("bookInfo", bookInfo);

        stage.set("tableOfContents");
        log("stage tableOfContents");
        int tocRequestStart = requests.length();
        int tocTraceStart = stageTrace.length();
        List<?> chapters;
        try {
            Object tocResult = runSuspend(loader, continuation -> selectedReference
                ? call(webBookClass, webBook, "getChapterListAwait", 5,
                    new Object[]{source, book, Boolean.FALSE, Boolean.FALSE}, continuation)
                : call(webBookClass, webBook, "getChapterListAwait", 4,
                    new Object[]{source, book, Boolean.FALSE}, continuation));
            chapters = unwrapResult(tocResult);
            if (chapters.isEmpty()) {
                throw new IllegalStateException("table of contents returned no chapter");
            }
        } catch (Exception error) {
            recordOperationError(observed, "tableOfContents", tocRequestStart, tocTraceStart, error);
            throw error;
        }
        recordOperation(observed, "tableOfContents", tocRequestStart, tocTraceStart);
        JSONArray chapterRows = new JSONArray();
        for (Object chapter : chapters) {
            chapterRows.put(chapterObservation(chapterClass, chapter));
        }
        observed.put("tableOfContents", new JSONObject()
            .put("tocUrl", str(bookClass, book, "getTocUrl"))
            .put("chapters", chapterRows));

        String sourceKey = (String) bookSourceClass.getMethod("getKey").invoke(source);
        Class<?> cacheClass = loader.loadClass("io.legado.app.help.CacheManager");
        Object cache = cacheClass.getField("INSTANCE").get(null);
        Method cacheGet = cacheClass.getMethod("get", String.class);
        Object vipProbe = cacheGet.invoke(cache, "v_" + sourceKey + "_vipProbe");
        Object payProbe = cacheGet.invoke(cache, "v_" + sourceKey + "_payProbe");
        observed.put("sourceProbes", new JSONObject()
            .put("vipProbe", vipProbe == null ? JSONObject.NULL : vipProbe)
            .put("payProbe", payProbe == null ? JSONObject.NULL : payProbe));

        if (TITLE_LIFECYCLE_TERMINAL.equals(observed.getString("terminal"))) {
            driveTitleLifecycle(observed, loader, source, book, chapters,
                bookClass, chapterClass, webBookClass, webBook);
        } else {
            stage.set("content");
            log("stage content");
            int contentRequestStart = requests.length();
            int contentTraceStart = stageTrace.length();
            Object text;
            try {
                text = runSuspend(loader, continuation -> call(webBookClass, webBook,
                    "getContentAwait", 6,
                    new Object[]{source, book, chapters.get(0), null, Boolean.FALSE}, continuation));
                if (selectedReference && !(text instanceof String)) {
                    throw new IllegalStateException("selected content result is not a string");
                }
            } catch (Exception error) {
                recordOperationError(observed, "content", contentRequestStart, contentTraceStart, error);
                throw error;
            }
            recordOperation(observed, "content", contentRequestStart, contentTraceStart);
            observed.put("chapter", new JSONObject()
                .put("title", str(chapterClass, chapters.get(0), "getTitle"))
                .put("text", text == null ? "" : text.toString()));
        }
        observed.put("requests", requestSlice(requestStart));
        caseRecords.put(observed);
    }

    /**
     * The declared saved-name/refresh observation: seed the two TOC chapters
     * with distinct raw variable text through the reference DAO, save the first
     * chapter's content with {@code needSave=true}, read the stored rows back,
     * run a real {@code getChapterListAwait} refresh, then publish the refreshed
     * list through the same DAO insert the reference book-information view model
     * uses and read the stored rows again.
     *
     * <p>Every row comes from a real object or DAO read; nothing is copied from
     * the seed or from an in-memory title assignment.
     */
    private void driveTitleLifecycle(JSONObject observed, ClassLoader loader, Object source,
            Object book, List<?> chapters, Class<?> bookClass, Class<?> chapterClass,
            Class<?> webBookClass, Object webBook) throws Exception {
        if (chapters.size() < LIFECYCLE_CHAPTERS) {
            throw new IllegalStateException("title lifecycle needs two TOC chapters");
        }
        JSONObject lifecycle = new JSONObject();
        // The write root is proven before BookHelp initialises or anything is saved.
        lifecycle.put("writeContainment", writeContainment(loader));

        String bookUrl = str(bookClass, book, "getBookUrl");
        Object dao = selectedDatabase.getClass().getMethod("getBookChapterDao")
            .invoke(selectedDatabase);
        java.lang.reflect.Method setVariable = chapterClass.getMethod("setVariable", String.class);
        for (int index = 0; index < LIFECYCLE_CHAPTERS; index++) {
            setVariable.invoke(chapters.get(index), SEED_VARIABLES[index]);
        }
        lifecycle.put("beforeContent", chapterRows(chapterClass, chapters));
        insertChapters(dao, chapters, chapterClass);

        JSONObject preference = setTocCountWords(loader, true);
        lifecycle.put("tocCountWords", preference);

        stage.set("content");
        log("stage content (saved)");
        int contentRequestStart = requests.length();
        int contentTraceStart = stageTrace.length();
        Object text;
        try {
            text = runSuspend(loader, continuation -> call(webBookClass, webBook,
                "getContentAwait", 6,
                new Object[]{source, book, chapters.get(0), null, Boolean.TRUE}, continuation));
            if (selectedReference && !(text instanceof String)) {
                throw new IllegalStateException("selected content result is not a string");
            }
        } catch (Exception error) {
            recordOperationError(observed, "content", contentRequestStart, contentTraceStart, error);
            throw error;
        }
        recordOperation(observed, "content", contentRequestStart, contentTraceStart);
        observed.put("chapter", new JSONObject()
            .put("title", str(chapterClass, chapters.get(0), "getTitle"))
            .put("text", text == null ? "" : text.toString()));
        lifecycle.put("storedAfterContent", storedRows(dao, bookUrl, chapterClass));
        lifecycle.put("contentFiles", contentFiles(loader, bookClass, book));

        stage.set("tableOfContents");
        log("stage tableOfContents (refresh)");
        int refreshRequestStart = requests.length();
        int refreshTraceStart = stageTrace.length();
        List<?> refreshed;
        try {
            Object tocResult = runSuspend(loader, continuation -> call(webBookClass, webBook,
                "getChapterListAwait", 5,
                new Object[]{source, book, Boolean.FALSE, Boolean.FALSE}, continuation));
            refreshed = unwrapResult(tocResult);
        } catch (Exception error) {
            recordOperationError(observed, "tableOfContents", refreshRequestStart, refreshTraceStart, error);
            throw error;
        }
        recordOperation(observed, "tableOfContents", refreshRequestStart, refreshTraceStart);
        lifecycle.put("refreshedChapters", chapterRows(chapterClass, refreshed));

        // The reference book-information view model publishes a refreshed list
        // with exactly this DAO insert (BookInfoViewModel.kt:527-532).
        insertChapters(dao, refreshed, chapterClass);
        lifecycle.put("storedAfterRefresh", storedRows(dao, bookUrl, chapterClass));
        lifecycle.put("tocCountWordsRestored", restoreTocCountWords(loader, preference));
        observed.put("titleLifecycle", lifecycle);
    }

    /**
     * The resolved content write root and database path, proven inside this
     * attempt's owned scratch root before the first save. Reading
     * {@code BookHelp.cachePath} is what initialises the class, so the check
     * runs before any {@code saveContent} call can exist.
     */
    private JSONObject writeContainment(ClassLoader loader) throws Exception {
        Object app = loader.loadClass("splitties.init.AppCtxKt")
            .getMethod("getAppCtx").invoke(null);
        Class<?> bookHelp = loader.loadClass("io.legado.app.help.book.BookHelp");
        Object cachePath = bookHelp.getMethod("getCachePath")
            .invoke(bookHelp.getField("INSTANCE").get(null));
        String cache = ((File) cachePath).getCanonicalPath();
        String root = scratch.root.getCanonicalPath();
        Object helper = selectedDatabase.getClass().getMethod("getOpenHelper")
            .invoke(selectedDatabase);
        Object database = helper.getClass().getMethod("getWritableDatabase").invoke(helper);
        String databasePath = new File((String) database.getClass().getMethod("getPath")
            .invoke(database)).getCanonicalPath();
        JSONObject containment = new JSONObject()
            .put("appCtxClass", app.getClass().getName())
            .put("cachePath", cache)
            .put("scratchRoot", root)
            .put("cachePathWithinScratch", within(cache, root))
            .put("databasePath", databasePath)
            .put("databasePathWithinScratch", within(databasePath, root));
        if (!containment.getBoolean("cachePathWithinScratch")
                || !containment.getBoolean("databasePathWithinScratch")
                || !"io.liber.oracle.nested.GuardedReaderApplication"
                    .equals(containment.getString("appCtxClass"))) {
            throw new IllegalStateException(
                "the content write root escapes the owned scratch: " + containment);
        }
        return containment;
    }

    private static boolean within(String path, String root) {
        return path.equals(root) || path.startsWith(root + File.separator);
    }

    /** The chapter files the content save actually wrote, under the proven root. */
    private JSONArray contentFiles(ClassLoader loader, Class<?> bookClass, Object book)
            throws Exception {
        Class<?> bookHelp = loader.loadClass("io.legado.app.help.book.BookHelp");
        Object cachePath = bookHelp.getMethod("getCachePath")
            .invoke(bookHelp.getField("INSTANCE").get(null));
        String folder = (String) bookClass.getMethod("getFolderName").invoke(book);
        File[] files = new File((File) cachePath, folder).listFiles();
        JSONArray names = new JSONArray();
        if (files != null) {
            java.util.Arrays.sort(files);
            for (File file : files) names.put(file.getName());
        }
        return names;
    }

    /** Ordered {@code {index,title,variable}} rows read from real chapter objects. */
    private JSONArray chapterRows(Class<?> chapterClass, List<?> chapters) throws Exception {
        JSONArray rows = new JSONArray();
        for (Object chapter : chapters) {
            Object variable = chapterClass.getMethod("getVariable").invoke(chapter);
            rows.put(new JSONObject()
                .put("index", chapterClass.getMethod("getIndex").invoke(chapter))
                .put("title", str(chapterClass, chapter, "getTitle"))
                .put("variable", variable == null ? JSONObject.NULL : variable));
        }
        return rows;
    }

    private JSONArray storedRows(Object dao, String bookUrl, Class<?> chapterClass)
            throws Exception {
        Object result = dao.getClass().getMethod("getChapterList", String.class)
            .invoke(dao, bookUrl);
        if (!(result instanceof List)) {
            throw new IllegalStateException("chapter DAO list absent");
        }
        return chapterRows(chapterClass, (List<?>) result);
    }

    private void insertChapters(Object dao, List<?> chapters, Class<?> chapterClass)
            throws Exception {
        Object array = java.lang.reflect.Array.newInstance(chapterClass, chapters.size());
        for (int index = 0; index < chapters.size(); index++) {
            java.lang.reflect.Array.set(array, index, chapters.get(index));
        }
        dao.getClass().getMethod("insert", array.getClass()).invoke(dao, array);
    }

    /**
     * The approved conditional restoration is gated on the reference
     * {@code tocCountWords} preference. It is written through the owned scratch
     * preference namespace and its previous value is recorded for the restore.
     */
    private JSONObject setTocCountWords(ClassLoader loader, boolean value) throws Exception {
        android.content.SharedPreferences preferences = defaultPreferences(loader);
        boolean previous = preferences.getBoolean(TOC_COUNT_WORDS, true);
        boolean committed = preferences.edit().putBoolean(TOC_COUNT_WORDS, value).commit();
        boolean observed = readTocCountWords(loader);
        if (!committed || observed != value) {
            throw new IllegalStateException("tocCountWords preference did not take effect");
        }
        return new JSONObject().put("name", TOC_COUNT_WORDS).put("previous", previous)
            .put("applied", value).put("observed", observed);
    }

    private boolean restoreTocCountWords(ClassLoader loader, JSONObject state) throws Exception {
        boolean previous = state.getBoolean("previous");
        boolean committed = defaultPreferences(loader).edit()
            .putBoolean(TOC_COUNT_WORDS, previous).commit();
        return committed && readTocCountWords(loader) == previous;
    }

    private android.content.SharedPreferences defaultPreferences(ClassLoader loader)
            throws Exception {
        Object app = loader.loadClass("splitties.init.AppCtxKt")
            .getMethod("getAppCtx").invoke(null);
        android.content.Context context = (android.content.Context) app;
        return context.getSharedPreferences(context.getPackageName() + "_preferences",
            android.content.Context.MODE_PRIVATE);
    }

    private boolean readTocCountWords(ClassLoader loader) throws Exception {
        Class<?> appConfig = loader.loadClass("io.legado.app.help.config.AppConfig");
        return (Boolean) appConfig.getMethod("getTocCountWords")
            .invoke(appConfig.getField("INSTANCE").get(null));
    }

    private void recordOperation(JSONObject observed, String name,
            int requestStart, int traceStart) throws Exception {
        observed.getJSONArray("operations").put(new JSONObject()
            .put("name", name)
            .put("outcome", "completed")
            .put("requestStart", requestStart)
            .put("requestEnd", requests.length())
            .put("traceStart", traceStart)
            .put("traceEnd", stageTrace.length()));
    }

    private void recordOperationError(JSONObject observed, String name,
            int requestStart, int traceStart, Exception error) throws Exception {
        observed.getJSONArray("operations").put(new JSONObject()
            .put("name", name)
            .put("outcome", "error")
            .put("requestStart", requestStart)
            .put("requestEnd", requests.length())
            .put("traceStart", traceStart)
            .put("traceEnd", stageTrace.length())
            .put("error", error.getClass().getName() + ": " + error.getMessage()));
    }

    private JSONObject chapterObservation(Class<?> chapterClass, Object chapter) throws Exception {
        Object tag = chapterClass.getMethod("getTag").invoke(chapter);
        return new JSONObject()
            .put("title", str(chapterClass, chapter, "getTitle"))
            .put("url", str(chapterClass, chapter, "getUrl"))
            .put("absoluteUrl", (String) chapterClass.getMethod("getAbsoluteURL").invoke(chapter))
            .put("tag", tag == null ? JSONObject.NULL : tag)
            .put("isVolume", Boolean.TRUE.equals(chapterClass.getMethod("isVolume").invoke(chapter)))
            .put("isVip", Boolean.TRUE.equals(chapterClass.getMethod("isVip").invoke(chapter)))
            .put("isPay", Boolean.TRUE.equals(chapterClass.getMethod("isPay").invoke(chapter)))
            .put("bookUrl", str(chapterClass, chapter, "getBookUrl"));
    }

    private JSONArray requestSlice(int start) throws JSONException {
        JSONArray slice = new JSONArray();
        for (int index = start; index < requests.length(); index++) {
            slice.put(requests.getJSONObject(index));
        }
        return slice;
    }

    private static JSONObject readAssetObject(Context context, String name) throws Exception {
        try (InputStream input = context.getAssets().open(name)) {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int read;
            while ((read = input.read(chunk)) > 0) buffer.write(chunk, 0, read);
            return new JSONObject(new String(buffer.toByteArray(), StandardCharsets.UTF_8));
        }
    }

    private byte[] readAssetBytes(String name) throws IOException {
        try (InputStream input = getContext().getAssets().open(name)) {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int read;
            while ((read = input.read(chunk)) > 0) buffer.write(chunk, 0, read);
            return buffer.toByteArray();
        }
    }

    private static String sha256(byte[] bytes) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
        StringBuilder hex = new StringBuilder(digest.length * 2);
        for (byte value : digest) {
            hex.append(Character.forDigit((value >> 4) & 0xf, 16));
            hex.append(Character.forDigit(value & 0xf, 16));
        }
        return hex.toString();
    }

    private static String sha256(File file) throws Exception {
        try (InputStream input = new java.io.FileInputStream(file)) {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int read;
            while ((read = input.read(chunk)) > 0) buffer.write(chunk, 0, read);
            return sha256(buffer.toByteArray());
        }
    }

    private static byte[] lf(byte[] bytes) {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        for (int index = 0; index < bytes.length; index++) {
            if (bytes[index] == '\r' && index + 1 < bytes.length && bytes[index + 1] == '\n') continue;
            output.write(bytes[index]);
        }
        return output.toByteArray();
    }

    /** One corpus case: the four stages in order, through the frozen entry points. */
    private void driveCase(JSONObject entry, String id) throws Exception {
        ClassLoader loader = getTargetContext().getClassLoader();
        JSONObject sourceJson = entry.getJSONObject("source");
        String keyword = entry.getString("keyword");

        Class<?> bookSourceClass = loader.loadClass("io.legado.app.data.entities.BookSource");
        Class<?> searchBookClass = loader.loadClass("io.legado.app.data.entities.SearchBook");
        Class<?> chapterClass = loader.loadClass("io.legado.app.data.entities.BookChapter");
        Class<?> bookClass = loader.loadClass("io.legado.app.data.entities.Book");
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        Object gson = loader.loadClass("com.google.gson.Gson").getConstructor().newInstance();
        Object source = gson.getClass()
            .getMethod("fromJson", String.class, Class.class)
            .invoke(gson, sourceJson.toString(), bookSourceClass);

        JSONObject observed = new JSONObject();

        stage.set("search");
        log("stage search");
        Object searchBooks = runSuspend(loader, continuation -> call(webBookClass, webBook,
            "searchBookAwait", 6,
            new Object[]{source, keyword, Integer.valueOf(1), null, null}, continuation));
        log("stage search returned");
        if (!(searchBooks instanceof List)) {
            throw new IllegalStateException("search returned " + searchBooks);
        }
        List<?> list = (List<?>) searchBooks;
        JSONArray results = new JSONArray();
        for (Object item : list) {
            results.put(new JSONObject()
                .put("name", str(searchBookClass, item, "getName"))
                .put("author", str(searchBookClass, item, "getAuthor"))
                .put("intro", str(searchBookClass, item, "getIntro"))
                .put("lastChapter", str(searchBookClass, item, "getLatestChapterTitle"))
                .put("wordCount", str(searchBookClass, item, "getWordCount")));
        }
        observed.put("search", new JSONObject().put("results", results));
        if (list.isEmpty()) throw new IllegalStateException("search returned no result");
        Object book = searchBookClass.getMethod("toBook").invoke(list.get(0));

        stage.set("bookInfo");
        log("stage bookInfo");
        runSuspend(loader, continuation -> call(webBookClass, webBook,
            "getBookInfoAwait", 4,
            new Object[]{source, book, Boolean.TRUE}, continuation));
        log("stage bookInfo returned");
        observed.put("bookInfo", new JSONObject()
            .put("name", str(bookClass, book, "getName"))
            .put("author", str(bookClass, book, "getAuthor"))
            .put("wordCount", str(bookClass, book, "getWordCount")));

        stage.set("tableOfContents");
        log("stage tableOfContents");
        Object tocResult = runSuspend(loader, continuation -> call(webBookClass, webBook,
            "getChapterListAwait", 4,
            new Object[]{source, book, Boolean.FALSE}, continuation));
        log("stage tableOfContents returned");
        List<?> chapters = unwrapResult(tocResult);
        if (chapters.isEmpty()) {
            throw new IllegalStateException("table of contents returned no chapter");
        }

        stage.set("content");
        log("stage content");
        // needSave=false: a synthetic corpus has no row in the frozen
        // application's database, so saving the chapter is a storage side effect
        // outside the compared surface. The ruleContent.title branch still runs
        // first, which is the observation this corpus is for.
        Object text = runSuspend(loader, continuation -> call(webBookClass, webBook,
            "getContentAwait", 6,
            new Object[]{source, book, chapters.get(0), null, Boolean.FALSE}, continuation));
        log("stage content returned");
        // The effective chapter title: ruleContent.title replaced it, or the
        // table of contents' own name stayed (BookContent.kt:64-72).
        observed.put("chapter", new JSONObject()
            .put("title", str(chapterClass, chapters.get(0), "getTitle"))
            .put("text", text == null ? "" : text.toString()));

        cases.put(id, observed);
    }

    /**
     * {@code BookSource.getCheckKeyword}: a nonblank {@code ruleSearch.checkKeyWord}
     * wins, a blank or absent one falls back to the caller's default
     * (BookSource.kt:208-215). A non-string value is either coerced by the
     * frozen Gson reader (a number) or rejected while the source is read (an
     * array or object), and both outcomes are recorded as observed.
     */
    private void observeCheckKeywords() throws Exception {
        ClassLoader loader = getTargetContext().getClassLoader();
        Class<?> bookSourceClass = loader.loadClass("io.legado.app.data.entities.BookSource");
        Object gson = loader.loadClass("com.google.gson.Gson").getConstructor().newInstance();
        Method fromJson = gson.getClass().getMethod("fromJson", String.class, Class.class);
        Method getCheckKeyword = bookSourceClass.getMethod("getCheckKeyword", String.class);
        JSONArray declared = corpus.getJSONArray("checkKeywordCases");
        for (int index = 0; index < declared.length(); index++) {
            JSONObject entry = declared.getJSONObject(index);
            String id = entry.getString("id");
            stage.set("checkKeyword:" + id);
            try {
                Object source = fromJson.invoke(gson, entry.getJSONObject("source").toString(),
                    bookSourceClass);
                Object value = getCheckKeyword.invoke(source, entry.getString("fallback"));
                checkKeyword.put(id, new JSONObject()
                    .put("outcome", "value")
                    .put("value", value == null ? JSONObject.NULL : value));
                log("checkKeyword " + id + " -> " + value);
            } catch (Throwable error) {
                Throwable cause = error instanceof InvocationTargetException
                    ? ((InvocationTargetException) error).getCause() : error;
                checkKeyword.put(id, new JSONObject()
                    .put("outcome", "refused")
                    .put("reason", describe(cause)));
                log("checkKeyword " + id + " refused: " + describe(cause));
            }
        }
    }

    /** Runs one suspend call through {@code kotlinx.coroutines.runBlocking}. */
    private Object runSuspend(ClassLoader loader, SuspendCall call) throws Exception {
        Class<?> builders = loader.loadClass("kotlinx.coroutines.BuildersKt");
        Method runBlocking = null;
        for (Method candidate : builders.getMethods()) {
            if (!candidate.getName().equals("runBlocking") || candidate.getParameterCount() != 2) {
                continue;
            }
            if (candidate.getParameterTypes()[1].getName().equals("kotlin.jvm.functions.Function2")) {
                runBlocking = candidate;
            }
        }
        if (runBlocking == null) throw new IllegalStateException("kotlinx runBlocking absent");
        Class<?> function2 = loader.loadClass("kotlin.jvm.functions.Function2");
        Object block = Proxy.newProxyInstance(loader, new Class<?>[]{function2},
            (proxy, method, args) -> {
                switch (method.getName()) {
                    case "invoke":
                        // (CoroutineScope scope, Continuation<?> continuation)
                        return call.run(args[1]);
                    case "toString":
                        return "fields-oracle-block";
                    case "hashCode":
                        return System.identityHashCode(proxy);
                    case "equals":
                        return args != null && args.length == 1 && proxy == args[0];
                    default:
                        return null;
                }
            });
        Object context = loader.loadClass("kotlin.coroutines.EmptyCoroutineContext")
            .getField("INSTANCE").get(null);
        try {
            return runBlocking.invoke(null, context, block);
        } catch (InvocationTargetException error) {
            Throwable cause = error.getCause();
            throw cause instanceof Exception ? (Exception) cause : new IllegalStateException(cause);
        }
    }

    /** One suspend method on the frozen singleton, with the continuation last. */
    private Object call(Class<?> owner, Object instance, String name, int parameterCount,
            Object[] arguments, Object continuation) throws Throwable {
        Method target = null;
        for (Method candidate : owner.getMethods()) {
            // A suspend function whose return type is an inline value class is name
            // mangled with a hash suffix (kotlin.Result -> getChapterListAwait-BWLJW6A,
            // the suffix this build observed on the device), so the base name is
            // matched as a prefix.
            if (!candidate.getName().equals(name)
                    && !candidate.getName().startsWith(name + "-")) {
                continue;
            }
            if (candidate.getParameterCount() != parameterCount) continue;
            if (!candidate.getParameterTypes()[parameterCount - 1].getName()
                    .equals("kotlin.coroutines.Continuation")) {
                continue;
            }
            if (selectedReference && target != null) {
                throw new IllegalStateException("ambiguous frozen suspend entry: " + name);
            }
            target = candidate;
        }
        if (target == null) throw new IllegalStateException("frozen suspend entry absent: " + name);
        if (selectedReference) selectedEntryPoints.put(name, target.toString());
        Log.i("FieldOracle", "frozen entry " + target.getName() + " on "
            + target.getDeclaringClass().getName());
        Object[] full = new Object[parameterCount];
        System.arraycopy(arguments, 0, full, 0, arguments.length);
        full[parameterCount - 1] = continuation;
        try {
            return target.invoke(instance, full);
        } catch (InvocationTargetException error) {
            throw error.getCause();
        }
    }

    /**
     * The value inside a {@code kotlin.Result}.
     *
     * {@code Result} is an inline value class and {@code getOrNull} is inlined,
     * so neither a class member nor a callable method exists on the boxed
     * instance. The boxed payload is taken from the synthetic {@code unbox-impl}
     * method, falling back to the private {@code value} field; a failure payload
     * surfaces the frozen exception instead of hiding it.
     */
    private static List<?> unwrapResult(Object result) throws Exception {
        if (result instanceof List) return (List<?>) result;
        if (result == null) throw new IllegalStateException("table of contents returned null");
        if ("kotlin.Result$Failure".equals(result.getClass().getName())) {
            throwFailure(result);
        }
        Object payload = null;
        for (Method candidate : result.getClass().getDeclaredMethods()) {
            if (candidate.getName().startsWith("unbox-impl")
                    && java.lang.reflect.Modifier.isStatic(candidate.getModifiers())
                    && candidate.getParameterCount() == 1) {
                candidate.setAccessible(true);
                payload = candidate.invoke(null, result);
            }
        }
        if (payload == null) {
            for (java.lang.reflect.Field field : result.getClass().getDeclaredFields()) {
                if (!field.getName().equals("value")) continue;
                field.setAccessible(true);
                payload = field.get(result);
            }
        }
        if (payload instanceof List) return (List<?>) payload;
        if (payload != null && payload.getClass().getName().contains("Failure")) {
            throwFailure(payload);
        }
        throw new IllegalStateException("table of contents result is "
            + result.getClass().getName() + " payload=" + payload);
    }

    private static void throwFailure(Object failure) throws Exception {
        for (java.lang.reflect.Field field : failure.getClass().getDeclaredFields()) {
            if (!field.getName().equals("exception")) continue;
            field.setAccessible(true);
            Object exception = field.get(failure);
            if (exception instanceof Exception) throw (Exception) exception;
            if (exception instanceof Throwable) throw new IllegalStateException((Throwable) exception);
        }
        throw new IllegalStateException("Kotlin Result.Failure has no exception payload");
    }

    private String str(Class<?> owner, Object instance, String getter) {
        try {
            Object value = owner.getMethod(getter).invoke(instance);
            if (selectedReference && !(value instanceof String)) {
                throw new IllegalStateException("selected getter is not a string: " + getter);
            }
            return value == null ? "" : value.toString();
        } catch (Exception error) {
            throw new IllegalStateException("frozen getter absent: " + getter, error);
        }
    }

    private String readAsset(String name) throws IOException {
        try (InputStream input = getContext().getAssets().open(name)) {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int read;
            while ((read = input.read(chunk)) > 0) buffer.write(chunk, 0, read);
            return new String(buffer.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    /** Writes the report; called after every case so a freeze keeps evidence. */
    private void writeReport() throws IOException, JSONException {
        try (FileOutputStream stream = new FileOutputStream(output)) {
            stream.write(report.toString(2).getBytes(StandardCharsets.UTF_8));
        }
    }

    private static String timestamp() {
        SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return format.format(new Date());
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

    private interface SuspendCall {
        Object run(Object continuation) throws Throwable;
    }

    /**
     * The corpus' replay server: every response comes from the corpus, an
     * undeclared request is answered 404 and recorded, and the port is the one
     * the corpus names. The matching rule is
     * {@code tool/first_slice/runner.dart}'s: a response that declares a
     * {@code query} wins over one that does not, and a declared query must match
     * the decoded request query exactly.
     */
    private static final class FieldReplay {
        private final JSONObject corpus;
        private final JSONArray requests;
        private final JSONArray unmatched;
        private final JSONArray serverErrors;
        private final JSONArray stageTrace;
        private final AtomicReference<String> stage;
        private final boolean receipts;
        private final ExecutorService clients = Executors.newFixedThreadPool(4);
        private final java.util.Set<Socket> openSockets = new java.util.HashSet<>();
        private ServerSocket server;
        private Thread worker;
        private String origin = "";
        private final java.util.concurrent.atomic.AtomicInteger open =
            new java.util.concurrent.atomic.AtomicInteger();
        /** Declaration-order cursor for a path a corpus declares more than once. */
        private final Map<String, Integer> pathCursors = new LinkedHashMap<>();

        FieldReplay(JSONObject corpus, JSONArray requests, JSONArray unmatched,
                JSONArray serverErrors, JSONArray stageTrace, AtomicReference<String> stage,
                boolean receipts) {
            this.corpus = corpus;
            this.requests = requests;
            this.unmatched = unmatched;
            this.serverErrors = serverErrors;
            this.stageTrace = stageTrace;
            this.stage = stage;
            this.receipts = receipts;
        }

        void start() throws Exception {
            origin = corpus.getString("origin");
            int port = Integer.parseInt(origin.substring(origin.lastIndexOf(':') + 1));
            server = new ServerSocket(port, 16, InetAddress.getByName("127.0.0.1"));
            worker = new Thread(this::accept, "fields-oracle-replay");
            worker.setDaemon(true);
            worker.start();
        }

        int openConnections() {
            return open.get();
        }

        void close() throws Exception {
            if (server != null) server.close();
            if (worker != null) {
                worker.join(2000);
                if (worker.isAlive()) throw new IllegalStateException("Replay worker did not stop");
            }
            // A keep-alive connection is parked in readLine and an interrupt does not
            // close a socket read, so the sockets are closed rather than waited out.
            synchronized (openSockets) {
                for (Socket socket : new ArrayList<>(openSockets)) {
                    try {
                        socket.close();
                    } catch (IOException ignored) {
                        // Already closed.
                    }
                }
                openSockets.clear();
            }
            clients.shutdownNow();
            if (!clients.awaitTermination(3, TimeUnit.SECONDS)) {
                throw new IllegalStateException("Replay clients did not stop");
            }
        }

        private void accept() {
            while (server != null && !server.isClosed()) {
                try {
                    final Socket client = server.accept();
                    open.incrementAndGet();
                    synchronized (openSockets) {
                        openSockets.add(client);
                    }
                    clients.submit(() -> {
                        try (Socket socket = client) {
                            serve(socket);
                        } catch (Exception error) {
                            // A socket closed by close() is the teardown, not a failure.
                            if (server != null && !server.isClosed()) {
                                synchronized (serverErrors) {
                                    serverErrors.put(error.toString());
                                }
                            }
                        } finally {
                            synchronized (openSockets) {
                                openSockets.remove(client);
                            }
                            open.decrementAndGet();
                        }
                    });
                } catch (IOException error) {
                    if (server != null && !server.isClosed()) {
                        synchronized (serverErrors) {
                            serverErrors.put(error.toString());
                        }
                    }
                }
            }
        }

        /** One connection can carry several requests: OkHttp keeps it alive. */
        private void serve(Socket socket) throws Exception {
            socket.setSoTimeout(20000);
            socket.setTcpNoDelay(true);
            BufferedReader reader = new BufferedReader(
                new InputStreamReader(socket.getInputStream(), StandardCharsets.ISO_8859_1));
            while (true) {
                String requestLine;
                try {
                    requestLine = reader.readLine();
                } catch (SocketTimeoutException idle) {
                    return;
                }
                if (requestLine == null || requestLine.isEmpty()) return;
                Map<String, String> headers = new LinkedHashMap<>();
                String line;
                while ((line = reader.readLine()) != null && !line.isEmpty()) {
                    int separator = line.indexOf(':');
                    if (separator <= 0) continue;
                    String name = line.substring(0, separator).trim().toLowerCase(Locale.US);
                    String value = line.substring(separator + 1).trim();
                    String existing = headers.get(name);
                    headers.put(name, existing == null ? value : existing + ", " + value);
                }
                int length = 0;
                String declaredLength = headers.get("content-length");
                if (declaredLength != null) {
                    try {
                        length = Integer.parseInt(declaredLength.trim());
                    } catch (NumberFormatException ignored) {
                        length = 0;
                    }
                }
                String body = "";
                if (length > 0) {
                    char[] buffer = new char[length];
                    int read = 0;
                    while (read < length) {
                        int count = reader.read(buffer, read, length - read);
                        if (count < 0) break;
                        read += count;
                    }
                    body = new String(buffer, 0, read);
                }
                String[] parts = requestLine.split(" ");
                String method = parts.length > 0 ? parts[0] : "";
                String target = parts.length > 1 ? parts[1] : "";
                String path = target;
                String rawQuery = "";
                int question = target.indexOf('?');
                if (question >= 0) {
                    path = target.substring(0, question);
                    rawQuery = target.substring(question + 1);
                }
                Map<String, String> query = decodeQuery(rawQuery);
                JSONObject observed = new JSONObject()
                    .put("method", method)
                    .put("path", path)
                    .put("query", new JSONObject(query))
                    .put("rawQuery", rawQuery)
                    .put("headers", new JSONObject(headers))
                    .put("body", body)
                    .put("stage", stage.get());
                synchronized (requests) {
                    requests.put(observed);
                    stageTrace.put(new JSONObject()
                        .put("stage", stage.get())
                        .put("path", origin + path
                            + (rawQuery.isEmpty() ? "" : "?" + rawQuery)));
                }
                OutputStream output = socket.getOutputStream();
                JSONObject declared = match(method, path, query);
                JSONObject receipt = null;
                if (receipts) {
                    receipt = new JSONObject()
                        .put("terminal", "pending")
                        .put("send", "pending")
                        .put("status", declared == null ? 404 : declared.optInt("status", 200))
                        .put("responseId", declared == null
                            ? JSONObject.NULL : declared.optString("id"))
                        .put("redirect", JSONObject.NULL);
                    JSONObject receiptHeaders = declared == null
                        ? null : declared.optJSONObject("headers");
                    if (receiptHeaders != null && receiptHeaders.has("Location")) {
                        receipt.put("redirect", receiptHeaders.optString("Location"));
                    }
                    observed.put("receipt", receipt);
                }
                try {
                    if (declared == null) {
                        synchronized (unmatched) {
                            unmatched.put(observed);
                        }
                        byte[] text = "undeclared replay request".getBytes(StandardCharsets.UTF_8);
                        output.write(("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
                            + "Content-Length: " + text.length + "\r\n\r\n")
                            .getBytes(StandardCharsets.US_ASCII));
                        output.write(text);
                    } else {
                        byte[] bytes = declared.optString("body", "").getBytes(StandardCharsets.UTF_8);
                        StringBuilder head = new StringBuilder();
                        head.append("HTTP/1.1 ").append(declared.optInt("status", 200)).append(" OK\r\n");
                        JSONObject declaredHeaders = declared.optJSONObject("headers");
                        if (declaredHeaders != null) {
                            Iterator<String> names = declaredHeaders.keys();
                            while (names.hasNext()) {
                                String name = names.next();
                                head.append(name).append(": ")
                                    .append(declaredHeaders.optString(name)).append("\r\n");
                            }
                        }
                        JSONArray setCookies = declared.optJSONArray("setCookies");
                        if (setCookies != null) {
                            for (int index = 0; index < setCookies.length(); index++) {
                                JSONObject cookie = setCookies.getJSONObject(index);
                                head.append("Set-Cookie: ").append(cookie.optString("name"))
                                    .append('=').append(cookie.optString("value"))
                                    .append("; Path=").append(cookie.optString("path", "/"))
                                    .append("\r\n");
                            }
                        }
                        head.append("Content-Length: ").append(bytes.length).append("\r\n\r\n");
                        output.write(head.toString().getBytes(StandardCharsets.US_ASCII));
                        output.write(bytes);
                    }
                    output.flush();
                    if (receipt != null) {
                        receipt.put("terminal", declared == null ? "unmatched" : "responded")
                            .put("send", "completed");
                    }
                } catch (Exception sendError) {
                    if (receipt != null) {
                        receipt.put("terminal", "send-failed")
                            .put("send", "failed")
                            .put("error", sendError.toString());
                    }
                    throw sendError;
                }
            }
        }

        private static Map<String, String> decodeQuery(String rawQuery) {
            Map<String, String> query = new LinkedHashMap<>();
            if (rawQuery.isEmpty()) return query;
            for (String pair : rawQuery.split("&")) {
                if (pair.isEmpty()) continue;
                int separator = pair.indexOf('=');
                String name = separator < 0 ? pair : pair.substring(0, separator);
                String value = separator < 0 ? "" : pair.substring(separator + 1);
                try {
                    query.put(URLDecoder.decode(name, "UTF-8"), URLDecoder.decode(value, "UTF-8"));
                } catch (Exception error) {
                    query.put(name, value);
                }
            }
            return query;
        }

        private JSONObject match(String method, String path, Map<String, String> query) {
            List<JSONObject> candidates = new ArrayList<>();
            JSONArray responses = corpus.optJSONArray("responses");
            if (responses == null) return null;
            for (int index = 0; index < responses.length(); index++) {
                JSONObject response = responses.optJSONObject(index);
                if (response == null) continue;
                if (!method.equals(response.optString("method"))) continue;
                if (!path.equals(response.optString("path"))) continue;
                candidates.add(response);
            }
            for (JSONObject candidate : candidates) {
                JSONObject declared = candidate.optJSONObject("query");
                if (declared == null) continue;
                if (declared.length() != query.size()) continue;
                boolean same = true;
                Iterator<String> names = declared.keys();
                while (names.hasNext()) {
                    String name = names.next();
                    if (!declared.optString(name).equals(query.get(name))) {
                        same = false;
                        break;
                    }
                }
                if (same) return candidate;
            }
            List<JSONObject> plain = new ArrayList<>();
            for (JSONObject candidate : candidates) {
                if (candidate.isNull("query")) plain.add(candidate);
            }
            if (plain.isEmpty()) return null;
            // A corpus that declares one response per path keeps the original
            // single answer. Only a corpus that declares several responses for
            // the same method and path is served in declaration order, which is
            // what the declared title-lifecycle TOC refresh needs.
            if (plain.size() == 1) return plain.get(0);
            String key = method + " " + path;
            int cursor = pathCursors.containsKey(key) ? pathCursors.get(key) : 0;
            pathCursors.put(key, cursor + 1);
            return cursor < plain.size() ? plain.get(cursor) : null;
        }
    }
}
