package io.liber.oracle.nested;

import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.Proxy;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TimeZone;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The frozen side of HTTP-BOUNDARY-01: drives the installed, hash-pinned
 * {@code io.legado.app.debug} ordinary HTTP boundary through reflection --
 * {@code JsExtensions.ajax/ajaxAll/connect}, {@code BaseSource.getHeaderMap},
 * {@code AnalyzeUrl.evalJS}, its rate-limiter record and the four real
 * {@code WebBook} suspend stage entries -- against one task-owned loopback replay
 * listener and one task-owned accept-and-close endpoint.
 *
 * <p>One process lifetime, one {@code seed} ownership binding. The collector
 * creates a fresh task-owned scratch root, records the corpus' 22 observations
 * and 31 ordinary HTTP requests, then stops admission, cancels owned jobs,
 * releases every gate, joins the server workers, closes the database, removes
 * the proven owned preference union and root, and emits the report only on the
 * BASE64 instrumentation stream.
 *
 * <p>Expected stage failures (empty table of contents, connection failure,
 * cancellation) are row outcomes; a reflection/API/type error, replay error,
 * deadline expiry or cleanup failure makes the capture incomplete. Negative
 * mode ({@code -e negative drop=<response-id>}) removes one declared helper
 * response after corpus validation, so the request reaches replay and produces
 * {@code unmatchedRequests}; a negative report is never promotable.
 *
 * <p>The harness reuses {@code StateSessionOracle.ScratchContext} for storage
 * containment and ships {@code tool/http_boundary/fixtures.json} as its asset.
 * No Legado class is rebuilt and no compared value is written by hand.
 */
public final class HttpBoundaryOracle extends Instrumentation {

    private static final String ASSET = "http-boundary-fixtures.json";
    private static final String STREAM_KEY = "HTTP_BOUNDARY_ORACLE_BASE64";
    private static final String SCRATCH_ROOT_NAME = "liber-http-boundary-01";
    private static final String PREFERENCE_PREFIX = "liber_http_boundary_01_";
    private static final String OWNER_FILE = "owner.json";
    private static final String NEGATIVE_PREFIX = "drop=";
    private static final int WATCHDOG_MILLIS = 240000;
    private static final long CLOSE_WAIT_MILLIS = 4000;

    private final JSONArray requests = new JSONArray();
    private final JSONArray unmatched = new JSONArray();
    private final JSONArray serverErrors = new JSONArray();
    private final JSONArray stageTrace = new JSONArray();
    private final JSONArray observations = new JSONArray();
    private final JSONObject inventory = new JSONObject();
    private final AtomicReference<String> stage = new AtomicReference<>("setup");
    private final AtomicBoolean finished = new AtomicBoolean();

    private StateSessionOracle.ScratchContext scratch;
    private Context application;
    private String negativeArg;
    private String runId;
    private JSONObject corpus;
    private JSONObject negativeBlock;
    private BoundaryReplay replay;
    private FailEndpoint failEndpoint;
    private Object database;
    private ClassLoader loader;
    private JSONObject identity;
    private JSONObject isolation;
    private JSONObject structural;
    private JSONObject runtimeConfiguration;
    private JSONObject rateLimiterInitial;
    private JSONObject rateLimiterFinal;
    private JSONObject rateLimiterCleanup;
    private JSONObject requestCheckValue;
    private JSONObject observationCheckValue;
    private boolean corpusIndexed;
    private String failureStage;
    private boolean cleanupOk;
    private boolean negativeMode;
    private boolean failEndpointOk;
    private boolean cohortsEntered;
    private String cancelToken;
    private JSONObject cancelExecution;
    private Object cancelExecutionJob;
    private Object cancelExecutionContext;
    private Object cancelExecutionSource;
    private String cancelExecutionSourceKey;
    private Object followUpJob;
    private Object activeCancelJob;
    private Method runBlockingMethod;
    private CancelMembers cancelMembers;
    private Thread activeCancelWorker;
    private boolean admissionStoppedReceipt;
    private boolean cancellationSignalledReceipt;
    private boolean gatesReleasedReceipt;
    private boolean replayOkReceipt;
    private boolean failOkReceipt;
    private boolean databaseClosedReceipt;
    private boolean databaseWasOpen;
    private boolean finalDatabaseSnapshotOk;
    private boolean ownedJobsTerminatedReceipt;
    private boolean terminalIntegrityOk;
    private String origin;
    private int threadCount;
    private final Map<String, Object> sourcesById = new LinkedHashMap<>();
    private final Map<String, Object> books = new LinkedHashMap<>();
    private final Map<String, Map<String, Object>> chapters = new LinkedHashMap<>();
    private final Map<String, Owner> selectorOwners = new LinkedHashMap<>();
    private final Map<String, JSONObject> responseById = new LinkedHashMap<>();
    private final Map<String, String> selectorResponseIds = new LinkedHashMap<>();
    private final Map<String, JSONObject> stepById = new LinkedHashMap<>();
    private final Map<String, Integer> declaredStepRequests = new LinkedHashMap<>();
    private final Map<String, Integer> derivedFamilyCounts = new LinkedHashMap<>();

    @Override
    public Application newApplication(ClassLoader cl, String name, Context context)
            throws InstantiationException, IllegalAccessException, ClassNotFoundException {
        scratch = new StateSessionOracle.ScratchContext(context, SCRATCH_ROOT_NAME,
            PREFERENCE_PREFIX);
        // A storage-only Application over the bound scratch context: frozen App.onCreate
        // (crash handler, file logging, Cronet, DefaultData, freeze monitor, LiveEventBus,
        // URL factory) never runs. No WebView API and no data-directory suffix is touched
        // anywhere in this collector.
        return super.newApplication(cl, Application.class.getName(), scratch);
    }

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        if (args != null) negativeArg = args.getString("negative");
        log("onCreate negative=" + negativeArg);
        new Handler(Looper.getMainLooper()).post(() -> {
            log("main looper reached; starting the worker thread");
            new Thread(this::run, "http-boundary-oracle").start();
        });
        startWatchdog();
    }

    private void startWatchdog() {
        Thread watchdog = new Thread(() -> {
            try {
                Thread.sleep(WATCHDOG_MILLIS);
            } catch (InterruptedException interrupted) {
                return;
            }
            if (finished.compareAndSet(false, true)) {
                String where = stage.get();
                log("watchdog: no result after " + WATCHDOG_MILLIS + "ms; stage=" + where);
                Bundle status = new Bundle();
                status.putString("stream", STREAM_KEY + "=" + base64(timeoutReport(where))
                    + "\nHTTP boundary oracle timed out in stage " + where
                    + " after " + requests.length() + " requests\n");
                finish(1, status);
            }
        }, "http-boundary-watchdog");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    private void log(String message) {
        Log.i("HttpBoundaryOracle", message);
    }

    // ------------------------------------------------------------------ run

    private void run() {
        Bundle status = new Bundle();
        JSONObject report = new JSONObject();
        boolean ok = false;
        String failure = null;
        JSONObject cleanup = new JSONObject();
        try {
            runId = UUID.randomUUID().toString();
            byte[] asset = readAsset(ASSET);
            corpus = new JSONObject(new String(asset, StandardCharsets.UTF_8));
            validateCorpus();
            indexCorpus();
            corpusIndexed = true;
            parseNegative();
            identity = measureIdentity(asset);
            scratch.bind("seed", identity);
            isolation = checkIsolation();
            database = loader.loadClass("io.legado.app.data.AppDatabaseKt")
                .getMethod("getAppDb").invoke(null);
            inventory.put("databaseOpened", true)
                .put("initial", dbCounts());
            rateLimiterInitial = rateLimiterSnapshot();
            if (!rateLimiterInitial.optBoolean("empty", false)) {
                throw new IllegalStateException("process-global rate-limiter state is not"
                    + " fresh: " + rateLimiterInitial);
            }
            failEndpoint = new FailEndpoint(corpus.getJSONObject("failureEndpoint"));
            failEndpoint.bind();
            replay = new BoundaryReplay(corpus, selectorOwners, requests, unmatched,
                serverErrors, stageTrace, stage, negativeMode
                    ? negativeBlock.optString("drop", "") : null, threadCount, origin);
            replay.start();
            log("replay listener bound: " + replay.endpoints()
                + "; fail endpoint bound on port " + failEndpoint.assignedPort);
            sourcesById.putAll(loadSources());
            drive();
            structural = structuralReport();
            requestCheckValue = requestCheck();
            observationCheckValue = observationCheck();
            cohortsEntered = replay.allCohortsEntered();
            failEndpointOk = failEndpoint.expectedOnly();
            JSONObject evaluation = evaluateSuccess();
            ok = evaluation.getBoolean("ok");
            if (!ok) failure = joinReasons(evaluation.getJSONArray("reasons"));
        } catch (Throwable error) {
            failure = describe(error);
            // A pre-bind refusal wakes provider preference waiters that otherwise crash
            // the process before this collector can publish its receipt. They remain
            // blocked on the shared binding latch; the controller force-stops the target
            // after the instrumentation result. A bound phase needs no refusal because
            // bind already released the latch. The shared helper is unchanged.
            if (scratch != null && scratch.isBound()) scratch.refuseWaiters(failure);
            log("failed in stage " + stage.get() + ": " + failure);
        } finally {
            failureStage = stage.get();
            stage.set("cleanup");
            try {
                cleanup = cleanup(ok);
                if (!cleanupOk && failure == null) {
                    failure = "cleanup: " + cleanup.optString("cleanupFailure",
                        "the collector's cleanup did not verify");
                }
                ok = ok && cleanupOk && terminalIntegrityOk;
            } catch (Throwable error) {
                ok = false;
                if (failure == null) failure = "cleanup: " + describe(error);
                try {
                    cleanup.put("cleanupFailure", describe(error));
                } catch (JSONException ignored) {
                    // The report below still carries the failure text.
                }
            }
            if (negativeMode) {
                ok = false;
                try {
                    boolean controlled = negativeSatisfied() && terminalIntegrityOk;
                    negativeBlock.put("integrityOk", terminalIntegrityOk)
                        .put("controlSatisfied", controlled);
                    if (!terminalIntegrityOk && failure == null) {
                        failure = "negative-control: the omission control did not preserve"
                            + " the rest of the trace's integrity";
                    } else if (controlled && failure == null) {
                        failure = "negative-control: replay omission reached admission and"
                            + " produced the intended unmatched terminal; this report is"
                            + " not promotable";
                    }
                } catch (JSONException ignored) {
                    // The failure text still names the mode.
                }
            }
            try {
                report.put("fixtureId", corpus == null ? "" : corpus.optString("fixtureId", ""))
                    .put("schemaVersion", corpus == null
                        ? JSONObject.NULL : Integer.valueOf(corpus.optInt("schemaVersion", -1)))
                    .put("corpusVersion", corpus == null
                        ? JSONObject.NULL : Integer.valueOf(corpus.optInt("corpusVersion", -1)))
                    .put("baselineCommit", corpus == null
                        ? "" : corpus.optString("baselineCommit", ""))
                    .put("entryPoint", corpus == null ? "" : corpus.optString("entryPoint", ""))
                    .put("platform", "android")
                    .put("fingerprint", Build.FINGERPRINT)
                    .put("recordedAt", timestamp())
                    .put("runId", runId == null ? "" : runId)
                    .put("pid", android.os.Process.myPid())
                    .put("captureKind", "frozen-device-capture-candidate")
                    .put("status", ok ? "ok" : "incomplete")
                    .put("promotable", ok && !negativeMode)
                    .put("terminalIntegrityOk", terminalIntegrityOk)
                    .put("setupCompleted", corpusIndexed && structural != null)
                    .put("setupStatus", !corpusIndexed ? "failed-before-index"
                        : structural == null ? "failed-after-index" : "completed")
                    .put("failureStage", failureStage == null ? "" : failureStage)
                    .put("identityStatus", identity == null
                        ? "not-measured" : "measured")
                    .put("notEvaluated", notEvaluatedAreas())
                    .put("negativeMode", negativeMode)
                    .put("negative", negativeBlock == null ? JSONObject.NULL : negativeBlock)
                    .put("identity", identity == null ? JSONObject.NULL : identity)
                    .put("structural", structural == null ? JSONObject.NULL : structural)
                    .put("isolation", isolation == null ? JSONObject.NULL : isolation)
                    .put("runtimeConfiguration", runtimeConfiguration == null
                        ? JSONObject.NULL : runtimeConfiguration)
                    .put("rateLimiter", new JSONObject()
                        .put("snapshotInitial", rateLimiterInitial == null
                            ? JSONObject.NULL : rateLimiterInitial)
                        .put("snapshotFinal", rateLimiterFinal == null
                            ? JSONObject.NULL : rateLimiterFinal)
                        .put("cleanup", rateLimiterCleanup == null
                            ? JSONObject.NULL : rateLimiterCleanup))
                    .put("failEndpoint", failEndpoint == null
                        ? JSONObject.NULL : failEndpoint.report())
                    .put("stageTrace", snapshot(stageTrace))
                    .put("requests", snapshot(requests))
                    .put("unmatchedRequests", snapshot(unmatched))
                    .put("serverErrors", snapshot(serverErrors))
                    .put("requestCheck", reportCheck("request"))
                    .put("observations", snapshot(observations))
                    .put("observationCheck", reportCheck("observation"))
                    .put("inventory", inventory)
                    .put("cleanup", cleanup)
                    .put("sourceDerivedNotes", corpus == null
                        ? JSONObject.NULL : corpus.optJSONObject("sourceDerivedNotes"))
                    .put("coverageGaps", corpus == null
                        ? JSONObject.NULL : corpus.optJSONArray("coverageGaps"))
                    .put("nondeterministic", corpus == null
                        ? JSONObject.NULL : corpus.optJSONArray("nondeterministic"))
                    .put("analysisFailure", failure == null ? JSONObject.NULL : failure);
            } catch (Throwable error) {
                ok = false;
                failure = (failure == null ? "" : failure + " | ")
                    + "report assembly: " + describe(error);
                log("report assembly failed: " + describe(error));
            }
            status.putString("stream", STREAM_KEY + "=" + base64(report.toString())
                + "\nHTTP boundary oracle: " + (failure == null
                    ? "recorded " + requests.length() + " requests, "
                        + observations.length() + " observations"
                    : "failed: " + failure) + "\n");
            log("report assembled; failure=" + failure);
            finished.set(true);
            finish(ok ? -1 : 1, status);
        }
    }

    // -------------------------------------------------------------- identity

    private JSONObject measureIdentity(byte[] asset) throws Exception {
        JSONObject target = corpus.getJSONObject("target");
        String targetPackage = target.getString("package");
        ApplicationInfo targetInfo = getTargetContext().getPackageManager()
            .getApplicationInfo(targetPackage, 0);
        String targetPath = targetInfo.sourceDir;
        String targetHash = sha256(new File(targetPath));
        if (!targetPackage.equals(getTargetContext().getPackageName())) {
            throw new IllegalStateException("instrumentation target is "
                + getTargetContext().getPackageName() + ", corpus names " + targetPackage);
        }
        if (!targetHash.equalsIgnoreCase(target.getString("apkSha256"))) {
            throw new IllegalStateException("installed target APK sha256 " + targetHash
                + " is not the corpus pin " + target.getString("apkSha256"));
        }
        String harnessPackage = getContext().getPackageName();
        String harnessPath = getContext().getPackageManager()
            .getApplicationInfo(harnessPackage, 0).sourceDir;
        return new JSONObject()
            .put("fixtureId", corpus.getString("fixtureId"))
            .put("corpusVersion", corpus.getInt("corpusVersion"))
            .put("targetPackage", targetPackage)
            .put("targetApkPath", targetPath)
            .put("targetApkSha256", targetHash)
            .put("targetBaselineCommit", target.getString("baselineCommit"))
            .put("targetPinManifest", target.getString("manifest"))
            .put("harnessPackage", harnessPackage)
            .put("harnessApkPath", harnessPath)
            .put("harnessApkSha256", sha256(new File(harnessPath)))
            .put("corpusAsset", ASSET)
            .put("corpusAssetSha256", sha256(asset))
            .put("corpusSha256Lf", sha256(lf(asset)))
            .put("corpusRawLineEndings", lineEndings(asset));
    }

    private JSONObject checkIsolation() throws Exception {
        loader = getTargetContext().getClassLoader();
        Context app = (Context) loader.loadClass("splitties.init.AppCtxKt")
            .getMethod("getAppCtx").invoke(null);
        application = app;
        if (!app.getClass().getName().startsWith("android.app.Application")) {
            throw new IllegalStateException("appCtx is not the storage-only application: "
                + app.getClass().getName());
        }
        if (app.isDeviceProtectedStorage()) {
            throw new IllegalStateException("the storage-only application is device-protected");
        }
        if (!app.getFilesDir().equals(scratch.getFilesDir())) {
            throw new IllegalStateException("appCtx escaped the scratch files directory: "
                + app.getFilesDir());
        }
        if (!app.getDatabasePath("legado.db").equals(scratch.getDatabasePath("legado.db"))) {
            throw new IllegalStateException("appCtx escaped the scratch database directory: "
                + app.getDatabasePath("legado.db"));
        }
        File dataDir = new File(getTargetContext().getApplicationInfo().dataDir,
            "shared_prefs");
        JSONObject probe = scratch.seedProbePreferences(app, dataDir,
            "liber_http_boundary_probe");
        if (probe.getBoolean("installationFile")
                || !probe.getBoolean("registered")
                || !probe.getBoolean("scopedFile")
                || !probe.getBoolean("committed")) {
            throw new IllegalStateException("appCtx preference storage is not scratch-scoped: "
                + probe);
        }
        runtimeConfiguration = readRuntimeConfiguration(app);
        return new JSONObject()
            .put("application", app.getClass().getName())
            .put("files", app.getFilesDir().toString())
            .put("database", app.getDatabasePath("legado.db").toString())
            .put("preferencesPrefix", scratch.preferencesPrefix())
            .put("preferencesLocation", corpus.getJSONObject("scratch")
                .getString("preferencesLocation"))
            .put("preferenceProbe", probe)
            .put("scratchRoot", scratch.root.getAbsolutePath())
            .put("scratchRootExistedAtStart", scratch.rootExistedAtStart())
            .put("scratchCreatedByThisRun", true)
            .put("deviceProtected", app.isDeviceProtectedStorage())
            .put("frozenAppOnCreate",
                "not-run: newApplication returns a storage-only android.app.Application, so"
                    + " io.legado.app.App.onCreate (crash handler, file logging, cronet"
                    + " pre-download, DefaultData.upVersion, freeze monitor, LiveEventBus,"
                    + " URL factory) does not run; the splitties AppCtxInitProvider is what"
                    + " this check measures")
            .put("webView",
                "not-initialized: this collector imports and calls no android.webkit API and"
                    + " sets no data-directory suffix");
    }

    /**
     * Reads the actual consumed threadCount from the isolated scratch AppCtx through the
     * frozen AppConfig member. An unavailable value makes the capture incomplete; no
     * default or unscoped preference is substituted.
     */
    private JSONObject readRuntimeConfiguration(Context app) throws Exception {
        JSONObject runtime = corpus.getJSONObject("runtime");
        String preferenceName = app.getPackageName() + "_preferences";
        final int value;
        try {
            Class<?> config = loader.loadClass("io.legado.app.help.config.AppConfig");
            Object instance = config.getField("INSTANCE").get(null);
            Object answer = config.getMethod("getThreadCount").invoke(instance);
            if (!(answer instanceof Number)) {
                throw new IllegalStateException("AppConfig.getThreadCount returned " + answer);
            }
            value = ((Number) answer).intValue();
        } catch (Throwable error) {
            throw new IllegalStateException("the actual consumed AppConfig.threadCount is"
                + " unresolved; the capture is incomplete: " + describe(error), error);
        }
        if (value < 1) {
            throw new IllegalStateException("resolved threadCount is not positive: " + value);
        }
        threadCount = value;
        return new JSONObject()
            .put("threadCount", value)
            .put("threadCountSource", runtime.getString("threadCountSource"))
            .put("threadCountPreference", runtime.getString("threadCountPreference"))
            .put("scopedPreferenceName", PREFERENCE_PREFIX + preferenceName)
            .put("appConfigMember", "io.legado.app.help.config.AppConfig.getThreadCount")
            .put("resolved", true)
            .put("readOnly", true);
    }

    // ------------------------------------------------------------ rate record

    /**
     * The frozen companion property is a private Kotlin static field. Resolve the actual
     * declaring class (outer class first, then the Companion) and read it without
     * clearing it. An unresolvable map makes every rate row incomplete, never a guess.
     */
    private Map<String, Object> resolveRateMap(JSONObject resolution) throws Exception {
        JSONObject rate = corpus.getJSONObject("rate");
        String fieldName = rate.getString("mapField");
        JSONArray candidates = rate.getJSONArray("mapOwnerCandidates");
        for (int index = 0; index < candidates.length(); index++) {
            String ownerName = candidates.getString(index);
            Class<?> owner;
            try {
                owner = loader.loadClass(ownerName);
            } catch (ClassNotFoundException absent) {
                continue;
            }
            Object companionInstance = null;
            if (ownerName.endsWith("$Companion")) {
                try {
                    companionInstance = owner.getField("INSTANCE").get(null);
                } catch (Throwable ignored) {
                    // The Companion object may not publish INSTANCE; its members are then
                    // static and are inspected below.
                }
            }
            for (Field field : owner.getDeclaredFields()) {
                if (!field.getName().contains(fieldName)) continue;
                if (!Map.class.isAssignableFrom(field.getType())) continue;
                try {
                    field.setAccessible(true);
                    Object map = Modifier.isStatic(field.getModifiers())
                        ? field.get(null) : field.get(companionInstance);
                    if (map instanceof Map) {
                        resolution.put("owner", ownerName)
                            .put("member", field.getName())
                            .put("access", Modifier.isStatic(field.getModifiers())
                                ? "static-field" : "companion-instance-field");
                        @SuppressWarnings("unchecked")
                        Map<String, Object> typed = (Map<String, Object>) map;
                        return typed;
                    }
                } catch (Throwable ignored) {
                    // Try the next candidate member.
                }
            }
            for (Method method : owner.getDeclaredMethods()) {
                if (!method.getName().contains(fieldName)) continue;
                if (method.getParameterCount() != 0) continue;
                if (!Map.class.isAssignableFrom(method.getReturnType())) continue;
                try {
                    method.setAccessible(true);
                    Object map = Modifier.isStatic(method.getModifiers())
                        ? method.invoke(null) : method.invoke(companionInstance);
                    if (map instanceof Map) {
                        resolution.put("owner", ownerName)
                            .put("member", method.getName())
                            .put("access", Modifier.isStatic(method.getModifiers())
                                ? "static-method" : "companion-instance-method");
                        @SuppressWarnings("unchecked")
                        Map<String, Object> typed = (Map<String, Object>) map;
                        return typed;
                    }
                } catch (Throwable ignored) {
                    // Try the next candidate member.
                }
            }
        }
        throw new IllegalStateException("the frozen concurrentRecordMap is unresolved;"
            + " rate rows are incomplete");
    }

    private JSONObject readRateRecord(Object record) throws Exception {
        if (record == null) return null;
        Class<?> type = record.getClass();
        String expectedClass = corpus.getJSONObject("rate").optString("recordClass", "");
        if (!expectedClass.isEmpty() && !expectedClass.equals(type.getName())) {
            throw new IllegalStateException("the rate record is " + type.getName()
                + ", the corpus pins " + expectedClass);
        }
        JSONObject out = new JSONObject();
        Object concurrent = memberValue(type, record,
            new String[]{"isConcurrent", "getIsConcurrent"});
        Object time = memberValue(type, record, new String[]{"getTime", "time"});
        Object frequency = memberValue(type, record, new String[]{"getFrequency", "frequency"});
        if (!(concurrent instanceof Boolean) || !(time instanceof Number)
                || !(frequency instanceof Number)) {
            throw new IllegalStateException("the frozen ConcurrentRecord fields are"
                + " unresolved: " + out);
        }
        return out.put("isConcurrent", ((Boolean) concurrent).booleanValue())
            .put("time", ((Number) time).longValue())
            .put("frequency", ((Number) frequency).intValue());
    }

    /** The frozen Java class name is intrahost provenance, never a compared value. */
    private static JSONObject readRateRecordProvenance(Object record) throws JSONException {
        JSONObject provenance = new JSONObject().put("present", record != null)
            .put("javaClassIsProvenance", true);
        if (record != null) {
            provenance.put("class", record.getClass().getName());
        }
        return provenance;
    }

    private static Object memberValue(Class<?> type, Object target, String[] names)
            throws Exception {
        for (String name : names) {
            try {
                Method method = type.getMethod(name);
                if (method.getParameterCount() == 0) return method.invoke(target);
            } catch (NoSuchMethodException absent) {
                // Try the field form.
            }
            try {
                Field field = type.getDeclaredField(name);
                field.setAccessible(true);
                return field.get(target);
            } catch (NoSuchFieldException absent) {
                // Try the next name.
            }
        }
        return null;
    }

    private Map<String, Object> activeRateMap() throws Exception {
        JSONObject resolution = new JSONObject();
        Map<String, Object> map = resolveRateMap(resolution);
        if (rateLimiterInitial != null && rateLimiterInitial.optJSONObject("resolution") == null) {
            rateLimiterInitial.put("resolution", resolution);
        }
        return map;
    }

    private JSONObject rateLimiterSnapshot() throws JSONException {
        JSONObject snapshot = new JSONObject();
        JSONObject resolution = new JSONObject();
        try {
            Map<String, Object> map = resolveRateMap(resolution);
            JSONArray entries = new JSONArray();
            synchronized (map) {
                List<String> keys = new ArrayList<>();
                for (Object key : map.keySet()) keys.add(String.valueOf(key));
                Collections.sort(keys);
                for (String key : keys) {
                    entries.put(new JSONObject().put("key", key)
                        .put("record", readRateRecord(map.get(key))));
                }
            }
            snapshot.put("resolved", true)
                .put("resolution", resolution)
                .put("size", entries.length())
                .put("entries", entries)
                .put("empty", entries.length() == 0);
        } catch (Throwable error) {
            snapshot.put("resolved", false)
                .put("empty", false)
                .put("error", describe(error));
        }
        return snapshot;
    }

    private Object rawRecordForSource(Object source) throws Exception {
        Map<String, Object> map = activeRateMap();
        String key = str(source.getClass(), source, "getKey");
        synchronized (map) {
            return map.get(key);
        }
    }

    private JSONObject removeOwnedRateRecords() throws JSONException {
        JSONObject receipt = new JSONObject();
        JSONObject resolution = new JSONObject();
        try {
            Map<String, Object> map = resolveRateMap(resolution);
            JSONArray removed = new JSONArray();
            JSONArray untouched = new JSONArray();
            JSONArray sourceKeys = new JSONArray();
            for (int index = 0; index < corpus.getJSONArray("sources").length(); index++) {
                JSONObject bookSource = corpus.getJSONArray("sources").getJSONObject(index)
                    .getJSONObject("bookSource");
                sourceKeys.put(bookSource.getString("bookSourceUrl")
                    .replace("$FAILPORT", String.valueOf(
                        failEndpoint == null ? -1 : failEndpoint.assignedPort)));
            }
            synchronized (map) {
                List<String> keys = new ArrayList<>();
                for (Object key : map.keySet()) keys.add(String.valueOf(key));
                Collections.sort(keys);
                for (String key : keys) {
                    boolean owned = false;
                    for (int index = 0; index < sourceKeys.length(); index++) {
                        if (sourceKeys.getString(index).equals(key)) owned = true;
                    }
                    if (owned) {
                        map.remove(key);
                        removed.put(key);
                    } else {
                        untouched.put(key);
                    }
                }
            }
            receipt.put("resolved", true)
                .put("resolution", resolution)
                .put("ownedKeys", sourceKeys)
                .put("removed", removed)
                .put("untouched", untouched);
        } catch (Throwable error) {
            receipt.put("resolved", false).put("error", describe(error));
        }
        return receipt;
    }

    // -------------------------------------------------------- corpus structure

    private void validateCorpus() throws Exception {
        if (!"HTTP-BOUNDARY-01".equals(corpus.getString("fixtureId"))
                || corpus.getInt("schemaVersion") != 1
                || corpus.getInt("corpusVersion") != 1) {
            throw new IllegalStateException("corpus is not HTTP-BOUNDARY-01 schema/version 1");
        }
        JSONObject target = corpus.getJSONObject("target");
        if (!"io.legado.app.debug".equals(target.getString("package"))) {
            throw new IllegalStateException("corpus targets another package");
        }
        if (!corpus.getString("baselineCommit").equals(target.getString("baselineCommit"))) {
            throw new IllegalStateException("corpus and target disagree on the baseline commit");
        }
        JSONObject scratchSpec = corpus.getJSONObject("scratch");
        if (!SCRATCH_ROOT_NAME.equals(scratchSpec.getString("rootName"))
                || !PREFERENCE_PREFIX.equals(scratchSpec.getString("preferencesPrefix"))) {
            throw new IllegalStateException("corpus scratch names do not match this collector");
        }
        JSONObject origins = corpus.getJSONObject("origins");
        if (origins.length() != 1) throw new IllegalStateException("corpus needs one origin");
        origin = origins.getString("replay");
        URI uri = URI.create(origin);
        if (uri.getHost() == null || uri.getPort() < 1 || !"127.0.0.1".equals(uri.getHost())) {
            throw new IllegalStateException("the replay origin is not an explicit loopback"
                + " host:port: " + origin);
        }
        JSONArray sources = corpus.getJSONArray("sources");
        if (sources.length() != 6) throw new IllegalStateException("corpus needs six sources");
        Set<String> sourceKeys = new LinkedHashSet<>();
        String concurrentRate = null;
        for (int index = 0; index < sources.length(); index++) {
            JSONObject entry = sources.getJSONObject(index);
            JSONObject bookSource = entry.getJSONObject("bookSource");
            String key = bookSource.getString("bookSourceUrl");
            if (!sourceKeys.add(key)) {
                throw new IllegalStateException("duplicate source key " + key);
            }
            if (bookSource.optBoolean("enabledCookieJar", false)) {
                throw new IllegalStateException("source " + entry.getString("id")
                    + " enables the cookie jar");
            }
            if (!bookSource.optString("loginUrl", "").isEmpty() || bookSource.has("jsLib")) {
                throw new IllegalStateException("source " + entry.getString("id")
                    + " declares a login script or jsLib");
            }
            String declaredUa;
            try {
                declaredUa = declaredHeaderUserAgent(bookSource.optString("header", ""));
            } catch (JSONException error) {
                throw new IllegalStateException("source " + entry.getString("id")
                    + " header is not the authored form: " + error, error);
            }
            if (!"HTTP-BOUNDARY-01/1.0".equals(declaredUa)) {
                throw new IllegalStateException("source " + entry.getString("id")
                    + " does not declare the corpus User-Agent in its header");
            }
            String rate = bookSource.optString("concurrentRate", "");
            if (!rate.isEmpty()) {
                if (concurrentRate != null) {
                    throw new IllegalStateException("two sources declare a concurrentRate");
                }
                concurrentRate = rate;
            }
        }
        if (!"1/2000".equals(concurrentRate)) {
            throw new IllegalStateException("the rate fixture is not the synthetic 1/2000: "
                + concurrentRate);
        }
        // The retry option is part of the row's causal declaration: S proves retry=2
        // (one attempt on 2xx, three on the non-2xx row) and F pins retry=0 so only the
        // transport layer can reconnect to the owned endpoint.
        for (int index = 0; index < sources.length(); index++) {
            JSONObject entry = sources.getJSONObject(index);
            String id = entry.getString("id");
            String searchUrl = entry.getJSONObject("bookSource").optString("searchUrl", "");
            if ("S".equals(id) && !searchUrl.endsWith(",{\"retry\":2}")) {
                throw new IllegalStateException("source S does not declare retry 2: "
                    + searchUrl);
            }
            if ("F".equals(id) && !searchUrl.endsWith(",{\"retry\":0}")) {
                throw new IllegalStateException("source F does not declare retry 0: "
                    + searchUrl);
            }
        }
        JSONArray responses = corpus.getJSONArray("responses");
        Set<String> responseIds = new LinkedHashSet<>();
        for (int index = 0; index < responses.length(); index++) {
            JSONObject response = responses.getJSONObject(index);
            String id = response.getString("id");
            if (!responseIds.add(id)) throw new IllegalStateException("duplicate response " + id);
            if (!(response.get("method") instanceof String)
                    || !(response.get("path") instanceof String)
                    || !(response.get("rawQuery") instanceof String)
                    || !(response.get("body") instanceof String)
                    || !(response.get("status") instanceof Number)) {
                throw new IllegalStateException("response " + id + " is missing a typed field");
            }
            if (response.getString("rawQuery").indexOf('?') >= 0) {
                throw new IllegalStateException("response " + id + " embeds '?' in rawQuery");
            }
            if (response.has("cohort") && !(response.get("cohort") instanceof String)) {
                throw new IllegalStateException("response " + id + " has an untyped cohort");
            }
            if (response.optBoolean("hold", false)
                    && !(response.get("holdTimeoutMs") instanceof Number)) {
                throw new IllegalStateException("held response " + id + " has no bound");
            }
        }
        JSONArray booksDeclared = corpus.getJSONArray("books");
        Set<String> bookIds = new LinkedHashSet<>();
        for (int index = 0; index < booksDeclared.length(); index++) {
            String id = booksDeclared.getJSONObject(index).getString("id");
            if (!bookIds.add(id)) throw new IllegalStateException("duplicate book " + id);
        }
        JSONArray cohorts = corpus.getJSONArray("cohorts");
        Set<String> cohortIds = new LinkedHashSet<>();
        for (int index = 0; index < cohorts.length(); index++) {
            JSONObject cohort = cohorts.getJSONObject(index);
            String id = cohort.getString("id");
            if (!cohortIds.add(id)) throw new IllegalStateException("duplicate cohort " + id);
            if (cohort.getInt("size") < 1 || cohort.getInt("timeoutMs") < 1) {
                throw new IllegalStateException("cohort " + id + " has no positive bound");
            }
        }
        JSONArray steps = corpus.getJSONArray("steps");
        Set<String> stepIds = new LinkedHashSet<>();
        for (int index = 0; index < steps.length(); index++) {
            JSONObject step = steps.getJSONObject(index);
            String id = step.getString("id");
            if (!stepIds.add(id)) throw new IllegalStateException("duplicate step " + id);
            String kind = step.getString("kind");
            if (!new LinkedHashSet<>(Arrays.asList("helper", "rate", "stage", "failure",
                    "cancel")).contains(kind)) {
                throw new IllegalStateException("unknown step kind " + kind);
            }
            String outcome = step.getString("expectedOutcome");
            if (!new LinkedHashSet<>(Arrays.asList("ok", "failure", "cancelled"))
                    .contains(outcome)) {
                throw new IllegalStateException("unknown expected outcome " + outcome + " in " + id);
            }
            if (!"ok".equals(outcome) && !step.has("expectedCategory")) {
                throw new IllegalStateException("expected failure row " + id
                    + " declares no category");
            }
            String family = step.getString("family");
            String sourceId = step.optString("source", "");
            if ("rate".equals(family) && !"R".equals(sourceId)) {
                throw new IllegalStateException("rate step " + id + " is not on source R");
            }
            if ("failure".equals(kind) && !"F".equals(sourceId)) {
                throw new IllegalStateException("failure step " + id + " is not on source F");
            }
            if ("cancel".equals(kind)) {
                if (!"S".equals(sourceId)) {
                    throw new IllegalStateException("cancel step " + id
                        + " is not on source S");
                }
                JSONArray ordered = step.getJSONObject("requests").getJSONArray("ordered");
                if (ordered.length() != 1) {
                    throw new IllegalStateException("cancel step " + id
                        + " does not declare exactly one held request");
                }
                JSONObject held = null;
                for (int slot = 0; slot < responses.length(); slot++) {
                    if (responses.getJSONObject(slot).getString("id")
                            .equals(ordered.getString(0))) {
                        held = responses.getJSONObject(slot);
                    }
                }
                if (held == null || !held.optBoolean("hold", false)) {
                    throw new IllegalStateException("cancel step " + id
                        + " does not request the held response");
                }
            }
            if (step.has("requiredHeaders")) {
                JSONObject headers = step.getJSONObject("requiredHeaders");
                Iterator<String> names = headers.keys();
                while (names.hasNext()) {
                    String name = names.next();
                    if (!name.equals(name.toLowerCase(Locale.US))) {
                        throw new IllegalStateException("step " + id
                            + " requires a non-lowercase header " + name);
                    }
                }
            }
        }
        if (!(corpus.getJSONObject("requestChecks").getJSONArray("forbiddenHeaders").length() > 0)) {
            throw new IllegalStateException("corpus declares no forbidden request headers");
        }
        JSONObject negative = corpus.getJSONObject("negative");
        if (!"replay-omission".equals(negative.getString("mode"))) {
            throw new IllegalStateException("corpus negative mode is not replay-omission");
        }
        if (!responseIds.contains(negative.getString("drop"))) {
            throw new IllegalStateException("corpus negative drop names no response");
        }
        JSONObject rate = corpus.getJSONObject("rate");
        if (!"1/2000".equals(rate.getString("concurrentRate"))
                || rate.getLong("windowMillis") != 2000) {
            throw new IllegalStateException("rate fixture semantics changed");
        }
        JSONObject failure = corpus.getJSONObject("failureEndpoint");
        if (!"127.0.0.1".equals(failure.getString("host"))
                || failure.getInt("port") != 0
                || !"$FAILPORT".equals(failure.getString("token"))) {
            throw new IllegalStateException("failure endpoint is not a task-owned"
                + " loopback ephemeral binding");
        }
    }

    /**
     * Derives every selector, its stable causal owner and the declared request/response
     * counts from the step declarations. Nothing is counted by prose: the corpus'
     * structural block is compared with the derived values.
     */
    private void indexCorpus() throws Exception {
        selectorOwners.clear();
        responseById.clear();
        selectorResponseIds.clear();
        stepById.clear();
        declaredStepRequests.clear();
        derivedFamilyCounts.clear();
        JSONArray responses = corpus.getJSONArray("responses");
        for (int index = 0; index < responses.length(); index++) {
            JSONObject response = responses.getJSONObject(index);
            String responseId = response.getString("id");
            responseById.put(responseId, response);
            selectorResponseIds.put(selectorOf(response), responseId);
        }
        JSONArray steps = corpus.getJSONArray("steps");
        int declaredTotal = 0;
        for (int index = 0; index < steps.length(); index++) {
            JSONObject step = steps.getJSONObject(index);
            String id = step.getString("id");
            String family = step.getString("family");
            stepById.put(id, step);
            int count = 0;
            Set<String> local = new LinkedHashSet<>();
            JSONObject spec = step.getJSONObject("requests");
            JSONArray ordered = spec.optJSONArray("ordered");
            if (ordered != null) {
                for (int slot = 0; slot < ordered.length(); slot++) {
                    String responseId = ordered.getString(slot);
                    JSONObject response = responseById.get(responseId);
                    if (response == null) {
                        throw new IllegalStateException("step " + id + " names undeclared"
                            + " response " + responseId);
                    }
                    registerSelector(selectorOf(response), id, family, null, local);
                    count++;
                }
            }
            JSONObject batch = spec.optJSONObject("batch");
            if (batch != null) {
                String cohortId = batch.getString("cohort");
                JSONArray members = batch.getJSONArray("members");
                for (int slot = 0; slot < members.length(); slot++) {
                    String responseId = members.getString(slot);
                    JSONObject response = responseById.get(responseId);
                    if (response == null) {
                        throw new IllegalStateException("step " + id + " names undeclared"
                            + " batch response " + responseId);
                    }
                    registerSelector(selectorOf(response), id, family, cohortId, local);
                    count++;
                }
            }
            declaredStepRequests.put(id, Integer.valueOf(count));
            declaredTotal += count;
            Integer prior = derivedFamilyCounts.get(family);
            derivedFamilyCounts.put(family, Integer.valueOf(prior == null ? 1
                : prior.intValue() + 1));
        }
        for (JSONObject response : responseById.values()) {
            String selector = selectorOf(response);
            if (!selectorOwners.containsKey(selector)) {
                throw new IllegalStateException("declared response " + response.optString("id")
                    + " is never requested by a step");
            }
        }
        // Each response selector belongs to exactly one causal step, and every response
        // that names a cohort is a member of the cohort a step declares.
        JSONArray cohorts = corpus.getJSONArray("cohorts");
        for (int index = 0; index < cohorts.length(); index++) {
            JSONObject cohort = cohorts.getJSONObject(index);
            String cohortId = cohort.getString("id");
            int members = 0;
            int declaredSteps = 0;
            for (JSONObject response : responseById.values()) {
                if (cohortId.equals(response.optString("cohort", ""))) members++;
            }
            for (JSONObject step : stepById.values()) {
                JSONObject batch = step.getJSONObject("requests").optJSONObject("batch");
                if (batch != null && cohortId.equals(batch.getString("cohort"))) declaredSteps++;
                if (batch != null && cohortId.equals(batch.getString("cohort"))
                        && batch.getJSONArray("members").length() != cohort.getInt("size")) {
                    throw new IllegalStateException("step " + step.getString("id")
                        + " declares a cohort with the wrong member count");
                }
            }
            if (members != cohort.getInt("size") || declaredSteps != 1) {
                throw new IllegalStateException("cohort " + cohortId + " has " + members
                    + " member responses and " + declaredSteps + " declaring steps");
            }
        }
        Integer helper = derivedFamilyCounts.get("helper");
        Integer rate = derivedFamilyCounts.get("rate");
        Integer stage = derivedFamilyCounts.get("stage");
        if (helper == null || rate == null || stage == null
                || helper.intValue() + rate.intValue() + stage.intValue() != steps.length()) {
            throw new IllegalStateException("step families do not cover the corpus: "
                + derivedFamilyCounts);
        }
        JSONObject structuralSpec = corpus.getJSONObject("structural");
        if (structuralSpec.getInt("requests") != declaredTotal) {
            throw new IllegalStateException("the corpus' declared request count "
                + structuralSpec.getInt("requests") + " is not the derived " + declaredTotal);
        }
        if (structuralSpec.getInt("observations") != steps.length()) {
            throw new IllegalStateException("the corpus' observation count is not derived");
        }
        if (structuralSpec.getInt("responses") != responses.length()) {
            throw new IllegalStateException("the corpus' response count is not derived");
        }
    }

    private void registerSelector(String selector, String step, String family, String cohort,
            Set<String> local) {
        Owner prior = selectorOwners.get(selector);
        if (prior != null && !prior.step.equals(step)) {
            throw new IllegalStateException("selector " + selector + " is owned by both "
                + prior.step + " and " + step);
        }
        selectorOwners.put(selector, new Owner(step, family, cohort));
        local.add(selector);
    }

    private JSONObject structuralReport() throws Exception {
        JSONArray steps = corpus.getJSONArray("steps");
        JSONArray responses = corpus.getJSONArray("responses");
        Set<String> helper = new LinkedHashSet<>();
        Set<String> rate = new LinkedHashSet<>();
        Set<String> stage = new LinkedHashSet<>();
        int total = 0;
        int singleton = 0;
        int batchSelectors = 0;
        JSONArray batchSizes = new JSONArray();
        int stageRequests = 0;
        for (int index = 0; index < steps.length(); index++) {
            JSONObject step = steps.getJSONObject(index);
            String family = step.getString("family");
            String id = step.getString("id");
            JSONObject spec = step.getJSONObject("requests");
            JSONArray ordered = spec.optJSONArray("ordered");
            JSONObject batch = spec.optJSONObject("batch");
            int count = declaredStepRequests.get(id).intValue();
            total += count;
            if ("helper".equals(family)) {
                if (ordered != null) {
                    for (int slot = 0; slot < ordered.length(); slot++) {
                        helper.add(selectorOf(responseById.get(ordered.getString(slot))));
                    }
                    if (batch == null) singleton += ordered.length();
                }
                if (batch != null) {
                    JSONArray members = batch.getJSONArray("members");
                    for (int slot = 0; slot < members.length(); slot++) {
                        helper.add(selectorOf(responseById.get(members.getString(slot))));
                    }
                    batchSelectors += members.length();
                    batchSizes.put(members.length());
                }
            } else if ("rate".equals(family)) {
                if (ordered != null) {
                    for (int slot = 0; slot < ordered.length(); slot++) {
                        rate.add(selectorOf(responseById.get(ordered.getString(slot))));
                    }
                }
            } else {
                if (ordered != null) {
                    for (int slot = 0; slot < ordered.length(); slot++) {
                        stage.add(selectorOf(responseById.get(ordered.getString(slot))));
                    }
                }
                if (batch != null) {
                    JSONArray members = batch.getJSONArray("members");
                    for (int slot = 0; slot < members.length(); slot++) {
                        stage.add(selectorOf(responseById.get(members.getString(slot))));
                    }
                }
                stageRequests += count;
            }
        }
        Set<String> all = new LinkedHashSet<>();
        all.addAll(helper);
        all.addAll(rate);
        all.addAll(stage);
        JSONObject derived = new JSONObject()
            .put("observations", steps.length())
            .put("requests", total)
            .put("responses", responses.length())
            .put("helperSelectors", helper.size())
            .put("helperSingletonSelectors", singleton)
            .put("helperBatchSelectors", batchSelectors)
            .put("helperBatchSizes", batchSizes)
            .put("rateSelectors", rate.size())
            .put("stageSelectors", stage.size())
            .put("stageRequests", stageRequests)
            .put("familyObservations", new JSONObject()
                .put("helper", derivedFamilyCounts.get("helper").intValue())
                .put("rate", derivedFamilyCounts.get("rate").intValue())
                .put("stage", derivedFamilyCounts.get("stage").intValue()))
            .put("requestsExceedingSelectors", total - all.size())
            .put("requestsExceedingSelectorsReason",
                "s2.retry-non2xx repeats one declared selector three times (retry=2)");
        JSONObject declared = corpus.getJSONObject("structural");
        return new JSONObject()
            .put("status", "structural-not-observed")
            .put("retryOptions", new JSONObject().put("S", 2).put("F", 0))
            .put("note", "these counts are derived from the declarations; neither capture"
                + " nor product observation exists until the controller runs it")
            .put("declared", declared)
            .put("derived", derived)
            .put("match", deepEqual(declared, derived));
    }

    private void parseNegative() throws Exception {
        negativeMode = negativeArg != null && !negativeArg.trim().isEmpty();
        if (!negativeMode) {
            negativeBlock = null;
            return;
        }
        String argument = negativeArg.trim();
        if (!argument.startsWith(NEGATIVE_PREFIX)) {
            throw new IllegalStateException("negative mode must be drop=<response-id>: "
                + argument);
        }
        String drop = argument.substring(NEGATIVE_PREFIX.length()).trim();
        JSONObject declared = corpus.getJSONObject("negative");
        if (!declared.getString("drop").equals(drop)) {
            throw new IllegalStateException("only the corpus' declared negative control is"
                + " accepted: " + declared.getString("drop"));
        }
        JSONObject response = responseById.get(drop);
        if (response == null) throw new IllegalStateException("negative drop names no response");
        String selector = selectorOf(response);
        if (!declared.getString("selector").equals(selector)) {
            throw new IllegalStateException("the negative drop selector changed: " + selector);
        }
        Owner owner = selectorOwners.get(selector);
        if (owner == null || !"helper".equals(owner.family)) {
            throw new IllegalStateException("the negative drop is not an ordinary helper"
                + " request");
        }
        if (!declared.getString("step").equals(owner.step)) {
            throw new IllegalStateException("the negative drop is owned by " + owner.step
                + ", the corpus declares " + declared.getString("step"));
        }
        negativeBlock = new JSONObject()
            .put("mode", "replay-omission")
            .put("drop", drop)
            .put("selector", selector)
            .put("step", owner.step)
            .put("declaredResponses", corpus.getJSONArray("responses").length())
            .put("activeResponses", corpus.getJSONArray("responses").length() - 1)
            .put("armedAtLoad", true)
            .put("controlSatisfied", false)
            .put("promotable", false);
    }

    private static String selectorOf(JSONObject value) throws JSONException {
        return value.getString("method") + " " + value.getString("path") + "?"
            + value.optString("rawQuery", "");
    }

    // ------------------------------------------------------------- drive

    private void drive() throws Throwable {
        JSONArray steps = corpus.getJSONArray("steps");
        for (int index = 0; index < steps.length(); index++) {
            JSONObject step = steps.getJSONObject(index);
            String id = step.getString("id");
            String kind = step.getString("kind");
            stage.set(id);
            log("step " + id + " (" + kind + ")");
            JSONObject row = new JSONObject().put("id", id);
            JSONObject value = new JSONObject();
            JSONObject evidence = new JSONObject();
            String outcome = "ok";
            String category = null;
            try {
                switch (kind) {
                    case "helper":
                        stepHelper(step, value, evidence);
                        break;
                    case "rate":
                        stepRate(step, value, evidence);
                        break;
                    case "stage":
                        if (step.optBoolean("executionBound", false)) {
                            stepFollowUp(step, value, evidence);
                        } else {
                            stepStage(step, value, evidence);
                        }
                        break;
                    case "failure":
                        stepConnectionFailure(step, value);
                        break;
                    case "cancel":
                        stepCancel(step, value, evidence);
                        break;
                    default:
                        throw new IllegalStateException("unknown step kind " + kind);
                }
            } catch (CancelledExecution expected) {
                outcome = "cancelled";
                category = "cancellation";
            } catch (IncompleteStep incomplete) {
                outcome = "incomplete";
                category = "unresolved-entry";
                evidence.put("incompleteReason", incomplete.reason);
            } catch (Throwable error) {
                category = categoryOf(error);
                outcome = "cancellation".equals(category) ? "cancelled" : "failure";
                evidence.put("rawError", describe(error));
            }
            row.put("outcome", outcome)
                .put("category", category == null ? JSONObject.NULL : category)
                .put("value", value)
                .put("evidence", evidence)
                .put("requests", sliceByOwner(id));
            synchronized (observations) {
                observations.put(row);
            }
        }
    }

    private JSONArray sliceByOwner(String id) throws JSONException {
        JSONArray slice = new JSONArray();
        synchronized (requests) {
            for (int index = 0; index < requests.length(); index++) {
                JSONObject request = requests.getJSONObject(index);
                if (id.equals(request.optString("owner", ""))) slice.put(request);
            }
        }
        return slice;
    }

    private Map<String, Object> loadSources() throws Exception {
        Class<?> bookSourceClass = loader.loadClass("io.legado.app.data.entities.BookSource");
        Object gson = loader.loadClass("com.google.gson.Gson").getConstructor().newInstance();
        Method fromJson = gson.getClass().getMethod("fromJson", String.class, Class.class);
        JSONArray declared = corpus.getJSONArray("sources");
        Map<String, Object> sources = new LinkedHashMap<>();
        for (int index = 0; index < declared.length(); index++) {
            JSONObject entry = declared.getJSONObject(index);
            JSONObject sourceJson = new JSONObject(entry.getJSONObject("bookSource").toString());
            rewriteFailPort(sourceJson);
            Object source = fromJson.invoke(gson, sourceJson.toString(), bookSourceClass);
            String key = str(bookSourceClass, source, "getBookSourceUrl");
            if (!key.equals(sourceJson.getString("bookSourceUrl"))) {
                throw new IllegalStateException("source " + entry.getString("id")
                    + " deserialised with a different key: " + key);
            }
            if (key.contains("$")) {
                throw new IllegalStateException("source " + entry.getString("id")
                    + " kept an unsubstituted token: " + key);
            }
            sources.put(entry.getString("id"), source);
        }
        return sources;
    }

    /**
     * The only declared fixture binding. $FAILPORT is substituted from the task-owned
     * listener's ephemeral port; it is not a general URL rewrite and no other token is
     * accepted.
     */
    private void rewriteFailPort(JSONObject sourceJson) throws JSONException {
        if (failEndpoint == null) {
            throw new IllegalStateException("the failure endpoint is not bound");
        }
        Iterator<String> names = sourceJson.keys();
        while (names.hasNext()) {
            String name = names.next();
            Object raw = sourceJson.get(name);
            if (!(raw instanceof String)) continue;
            String value = (String) raw;
            if (value.indexOf('$') < 0) continue;
            if (!value.contains("$FAILPORT")) {
                throw new IllegalStateException("source field " + name
                    + " carries an undeclared token: " + value);
            }
            sourceJson.put(name, value.replace("$FAILPORT",
                String.valueOf(failEndpoint.assignedPort)));
        }
    }

    private Object require(Map<String, Object> map, String id, String what) {
        Object value = map.get(id);
        if (value == null) throw new IllegalStateException("no " + what + " bound for " + id);
        return value;
    }

    private JSONObject declaredBook(String id) throws JSONException {
        JSONArray declared = corpus.getJSONArray("books");
        for (int index = 0; index < declared.length(); index++) {
            JSONObject book = declared.getJSONObject(index);
            if (book.getString("id").equals(id)) return book;
        }
        throw new IllegalStateException("corpus declares no book " + id);
    }

    // -------------------------------------------------------------- helpers

    private void stepHelper(JSONObject step, JSONObject value, JSONObject evidence)
            throws Throwable {
        String sourceId = step.getString("source");
        Object source = require(sourcesById, sourceId, "source");
        String action = step.getString("action");
        value.put("kind", "helper").put("action", action).put("source", sourceId);
        if ("headerMap".equals(action)) {
            // The measured surface is the real rule-script boundary: AnalyzeUrl.evalJS
            // binds `source`, and one fixture-authored projection script per arity calls
            // source.getHeaderMap/<arity> and returns only primitives. A thrown arity is
            // a real measured outcome; a Kotlin default-argument call is separate,
            // explicitly labelled provenance and never the zero-argument script result.
            JSONObject scripts = step.getJSONObject("scripts");
            Object host;
            try {
                host = newAnalyzeUrl(source);
            } catch (Throwable error) {
                throw new IncompleteStep("the header-map AnalyzeUrl binding is unresolved: "
                    + describe(error));
            }
            JSONObject arities = new JSONObject();
            JSONObject arityProvenance = new JSONObject();
            for (String arity : new String[]{"zero", "falseArity", "trueArity"}) {
                String script = scripts.getString(arity);
                Object rawResult;
                try {
                    rawResult = evalJS(host, script);
                } catch (Throwable error) {
                    String message = error.getMessage() == null ? "" : error.getMessage();
                    if (message.contains("AnalyzeUrl.evalJS absent")) {
                        throw new IncompleteStep("the header-map evaluator is unresolved: "
                            + describe(error));
                    }
                    arities.put(arity, new JSONObject().put("returned", false));
                    arityProvenance.put(arity, new JSONObject()
                        .put("errorType", error.getClass().getName())
                        .put("rawEngineError", describe(error))
                        .put("engineErrorIsProvenance", true));
                    continue;
                }
                if (rawResult == null) {
                    arities.put(arity, new JSONObject().put("returned", false));
                    arityProvenance.put(arity, new JSONObject()
                        .put("errorType", "null-result")
                        .put("rawEngineError", "the script returned null")
                        .put("engineErrorIsProvenance", true));
                    continue;
                }
                JSONObject measured;
                JSONArray pairs;
                try {
                    measured = new JSONObject(String.valueOf(rawResult));
                    pairs = measured.optJSONArray("value");
                } catch (Throwable error) {
                    throw new IncompleteStep("the header-map " + arity
                        + " script did not return the primitive JSON projection: "
                        + describe(error));
                }
                if (pairs == null) {
                    throw new IncompleteStep("the header-map " + arity
                        + " script returned no primitive map projection");
                }
                JSONArray checked = new JSONArray();
                for (int slot = 0; slot < pairs.length(); slot++) {
                    JSONArray pair = pairs.optJSONArray(slot);
                    if (pair == null || pair.length() != 2
                            || !(pair.get(0) instanceof String)
                            || !(pair.get(1) instanceof String)) {
                        throw new IncompleteStep("the header-map " + arity
                            + " map projection is not an array of string pairs");
                    }
                    checked.put(new JSONArray().put(pair.getString(0))
                        .put(pair.getString(1)));
                }
                arities.put(arity, new JSONObject().put("returned", true)
                    .put("value", checked));
            }
            JSONObject zeroDefault = new JSONObject()
                .put("provenanceOnly", true)
                .put("notScriptResult", true)
                .put("jobLevel", "kotlin-default-argument");
            try {
                Map<?, ?> defaultMap = zeroArityHeaderMap(source, zeroDefault);
                zeroDefault.put("resolved", true).put("value", jsonMap(defaultMap));
            } catch (Throwable error) {
                zeroDefault.put("resolved", false).put("error", describe(error));
            }
            arityProvenance.put("zeroDefaultProvenance", zeroDefault);
            arityProvenance.put("scripts", scripts);
            arityProvenance.put("headerRule", str(source.getClass(), source, "getHeader"));
            value.put("kind", "headerMap").put("action", "headerMap")
                .put("source", sourceId).put("arities", arities);
            evidence.put("arityProvenance", arityProvenance);
            return;
        }
        Object host = newAnalyzeUrl(source);
        Object result = evalJS(host, step.getString("script"));
        value.put("result", result == null ? JSONObject.NULL : String.valueOf(result));
        evidence.put("javaType", result == null ? JSONObject.NULL : result.getClass().getName());
        JSONObject spec = step.getJSONObject("requests");
        JSONObject batch = spec.optJSONObject("batch");
        if (batch != null) {
            value.put("batch", replay.batchReport(batch.getString("cohort")));
            evidence.put("batch", replay.batchEvidence(batch.getString("cohort")));
        }
    }

    /**
     * The Kotlin default-argument entry, used only as provenance for the source's
     * declared default. It is never reported as the zero-argument script result.
     */
    private Map<?, ?> zeroArityHeaderMap(Object source, JSONObject provenance)
            throws Exception {
        for (String name : new String[]{"io.legado.app.data.entities.BaseSource",
                "io.legado.app.data.entities.BaseSource$DefaultImpls"}) {
            Class<?> owner;
            try {
                owner = loader.loadClass(name);
            } catch (ClassNotFoundException absent) {
                continue;
            }
            List<Method> candidates = new ArrayList<>();
            candidates.addAll(Arrays.asList(owner.getDeclaredMethods()));
            candidates.addAll(Arrays.asList(owner.getMethods()));
            for (Method method : candidates) {
                if (!method.getName().equals("getHeaderMap$default")) continue;
                if (method.getParameterCount() != 4) continue;
                method.setAccessible(true);
                Object answer = method.invoke(null, source, Boolean.FALSE, Integer.valueOf(1),
                    null);
                provenance.put("member", name + "." + method.getName());
                return (Map<?, ?>) answer;
            }
        }
        throw new IllegalStateException("the Kotlin default-argument getHeaderMap is"
            + " unresolved; the script arities remain the measured surface");
    }

    private Object newAnalyzeUrl(Object source) throws Exception {
        Class<?> urlClass = loader.loadClass("io.legado.app.model.analyzeRule.AnalyzeUrl");
        Constructor<?> constructor = null;
        for (Constructor<?> candidate : urlClass.getConstructors()) {
            if (candidate.getParameterCount() != 14) continue;
            Class<?>[] types = candidate.getParameterTypes();
            if (types[0] == String.class && types[13] == Boolean.TYPE) constructor = candidate;
        }
        if (constructor == null) {
            throw new IllegalStateException("frozen AnalyzeUrl constructor absent");
        }
        Object context = loader.loadClass("kotlin.coroutines.EmptyCoroutineContext")
            .getField("INSTANCE").get(null);
        String key = str(source.getClass(), source, "getKey");
        return constructor.newInstance(key, null, null, null, null, key, source, null, null,
            null, null, context, null, Boolean.TRUE);
    }

    private Object evalJS(Object host, String script) throws Exception {
        Method eval = null;
        for (Method candidate : host.getClass().getMethods()) {
            if (!candidate.getName().equals("evalJS")) continue;
            if (candidate.getParameterCount() != 2) continue;
            if (candidate.getParameterTypes()[0] != String.class) continue;
            eval = candidate;
        }
        if (eval == null) throw new IllegalStateException("frozen AnalyzeUrl.evalJS absent");
        try {
            return eval.invoke(host, script, null);
        } catch (InvocationTargetException error) {
            Throwable cause = error.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            throw new IllegalStateException(cause);
        }
    }

    // ----------------------------------------------------------------- rate

    private void stepRate(JSONObject step, JSONObject value, JSONObject evidence)
            throws Throwable {
        Object source = require(sourcesById, step.getString("source"), "source");
        int index = step.getInt("index");
        Object beforeRaw;
        JSONObject before;
        try {
            beforeRaw = rawRecordForSource(source);
            before = readRateRecord(beforeRaw);
        } catch (Throwable error) {
            throw new IncompleteStep("rate record is unresolved before rate.record." + index
                + ": " + describe(error));
        }
        long startMillis = System.currentTimeMillis();
        long startNanos = System.nanoTime();
        Object host = newAnalyzeUrl(source);
        Object result = evalJS(host, step.getString("script"));
        long finishMillis = System.currentTimeMillis();
        long finishNanos = System.nanoTime();
        Object afterRaw;
        JSONObject after;
        try {
            afterRaw = rawRecordForSource(source);
            after = readRateRecord(afterRaw);
        } catch (Throwable error) {
            throw new IncompleteStep("rate record is unresolved after rate.record." + index
                + ": " + describe(error));
        }
        if (after == null) {
            throw new IncompleteStep("no rate record after rate.record." + index);
        }
        long window = corpus.getJSONObject("rate").getLong("windowMillis");
        Boolean sameWindow = null;
        boolean complete = true;
        StringBuilder reason = new StringBuilder();
        if (index == 1) {
            if (before != null) {
                complete = false;
                reason.append("the map was not empty before the first admission; ");
            }
            if (after.getInt("frequency") != 1) {
                complete = false;
                reason.append("the first record is not frequency 1; ");
            }
            if (startMillis >= after.getLong("time") + window) {
                complete = false;
                reason.append("the first call started after its own window; ");
            }
        } else if (index == 2) {
            if (before == null) {
                complete = false;
                reason.append("the second admission has no first record; ");
            } else {
                sameWindow = Boolean.valueOf(after.getLong("time") == before.getLong("time"));
                if (!sameWindow.booleanValue()) {
                    complete = false;
                    reason.append("the second admission started a new window; ");
                }
                if (after.getInt("frequency") != 2) {
                    complete = false;
                    reason.append("the second record is not frequency 2; ");
                }
                if (startMillis >= before.getLong("time") + window) {
                    complete = false;
                    reason.append("the second call was outside the first window; ");
                }
            }
        } else {
            if (before == null) {
                complete = false;
                reason.append("the third admission has no second record; ");
            } else {
                sameWindow = Boolean.valueOf(after.getLong("time") == before.getLong("time"));
                long advance = after.getLong("time") - before.getLong("time");
                evidence.put("windowAdvanceMillis", advance);
                if (advance < window) {
                    complete = false;
                    reason.append("the third admission did not respect the window; ");
                }
                if (after.getInt("frequency") != 1) {
                    complete = false;
                    reason.append("the third record did not reset to frequency 1; ");
                }
            }
        }
        if (!after.getBoolean("isConcurrent")) {
            complete = false;
            reason.append("the record is not a concurrent record; ");
        }
        value.put("kind", "rate").put("index", index)
            .put("result", result == null ? JSONObject.NULL : String.valueOf(result))
            .put("recordBefore", before == null ? JSONObject.NULL : before)
            .put("recordAfter", after)
            .put("sameWindowAsPrevious", sameWindow == null ? JSONObject.NULL : sameWindow)
            .put("scheduleComplete", complete)
            .put("scheduleReason", reason.length() == 0
                ? JSONObject.NULL : reason.toString().trim());
        evidence.put("callStartMillis", startMillis)
            .put("callFinishMillis", finishMillis)
            .put("durationNanos", finishNanos - startNanos)
            .put("sourceKey", str(source.getClass(), source, "getKey"))
            .put("rate", new JSONObject()
                .put("recordClassBefore", readRateRecordProvenance(beforeRaw))
                .put("recordClassAfter", readRateRecordProvenance(afterRaw)));
        if (!complete) {
            throw new IncompleteStep("incomplete-schedule: rate.record." + index + ": "
                + reason.toString().trim());
        }
    }

    // --------------------------------------------------------------- stages

    private void stepStage(JSONObject step, JSONObject value, JSONObject evidence)
            throws Throwable {
        Object source = require(sourcesById, step.getString("source"), "source");
        String stageKind = step.getString("stage");
        value.put("kind", "stage").put("stage", stageKind)
            .put("source", step.getString("source"));
        switch (stageKind) {
            case "search":
                stageSearch(step, source, value);
                break;
            case "details":
                stageDetails(step, source, value);
                break;
            case "toc":
                stageToc(step, source, value);
                break;
            case "content":
                stageContent(step, source, value);
                break;
            default:
                throw new IllegalStateException("unknown stage " + stageKind);
        }
        JSONObject batch = step.getJSONObject("requests").optJSONObject("batch");
        if (batch != null) {
            value.put("batch", replay.batchReport(batch.getString("cohort")));
            evidence.put("batch", replay.batchEvidence(batch.getString("cohort")));
        }
    }

    private void stageSearch(JSONObject step, Object source, JSONObject value) throws Throwable {
        recordSearchResults(step, search(source, step.getString("keyword")), value);
    }

    private void recordSearchResults(JSONObject step, Object result, JSONObject value)
            throws Throwable {
        if (!(result instanceof List)) {
            throw new IllegalStateException("search returned "
                + (result == null ? "null" : result.getClass().getName()));
        }
        List<?> list = (List<?>) result;
        JSONArray expect = step.getJSONArray("expectBooks");
        if (list.size() != expect.length()) {
            throw new IllegalStateException("search returned " + list.size()
                + " results, corpus declares " + expect.length());
        }
        Class<?> searchBookClass = loader.loadClass("io.legado.app.data.entities.SearchBook");
        Class<?> bookClass = loader.loadClass("io.legado.app.data.entities.Book");
        JSONArray observed = new JSONArray();
        for (int index = 0; index < expect.length(); index++) {
            String bookId = expect.getString(index);
            JSONObject declared = declaredBook(bookId);
            Object item = list.get(index);
            Object book = searchBookClass.getMethod("toBook").invoke(item);
            String bookUrl = str(bookClass, book, "getBookUrl");
            if (!bookUrl.equals(declared.getString("bookUrl"))) {
                throw new IllegalStateException("search result " + bookId + " is " + bookUrl
                    + ", corpus declares " + declared.getString("bookUrl"));
            }
            observed.put(new JSONObject()
                .put("id", bookId)
                .put("name", str(searchBookClass, item, "getName"))
                .put("author", str(searchBookClass, item, "getAuthor"))
                .put("kind", nullToNull(call(item, "getKind")))
                .put("bookUrl", bookUrl)
                .put("origin", str(searchBookClass, item, "getOrigin"))
                .put("originName", str(searchBookClass, item, "getOriginName"))
                .put("coverUrl", nullToNull(call(item, "getCoverUrl")))
                .put("intro", nullToNull(call(item, "getIntro")))
                .put("wordCount", nullToNull(call(item, "getWordCount")))
                .put("latestChapterTitle", nullToNull(call(item, "getLatestChapterTitle")))
                .put("type", ((Number) call(item, "getType")).intValue()));
            books.put(bookId, book);
        }
        value.put("results", observed);
    }

    private Object search(Object source, String keyword) throws Throwable {
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        return runSuspend(loader, continuation -> callSuspend(webBookClass, webBook,
            "searchBookAwait", 6,
            new Object[]{source, keyword, Integer.valueOf(1), null, null}, continuation));
    }

    private Object searchUnderContext(Object context, Object source, String keyword)
            throws Throwable {
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        return runBlockingWithContext(context, continuation -> callSuspend(webBookClass,
            webBook, "searchBookAwait", 6,
            new Object[]{source, keyword, Integer.valueOf(1), null, null}, continuation));
    }

    /**
     * The post-cancellation search is bound before invocation to its own created-parent
     * Job/context and the same source object/key. Freshness is measured by object
     * identity at the same created-parent level, not by a post-search UUID.
     */
    private void stepFollowUp(JSONObject step, JSONObject value, JSONObject evidence)
            throws Throwable {
        String followUpStep = corpus.getJSONObject("cancellation")
            .optString("followUpStep", "");
        if (!followUpStep.equals(step.getString("id"))) {
            throw new IncompleteStep("the execution-bound step is not the declared"
                + " follow-up: " + step.getString("id"));
        }
        Object source = require(sourcesById, step.getString("source"), "source");
        String keyword = step.getString("keyword");
        value.put("kind", "stage").put("stage", "search")
            .put("source", step.getString("source"));
        CancelMembers members;
        try {
            members = resolveCancelMembers();
        } catch (Throwable error) {
            throw new IncompleteStep("the follow-up execution entry is unresolved: "
                + describe(error));
        }
        Object job = members.newJob.invoke(null, new Object[]{null});
        Object context = members.plus.invoke(members.emptyContext, job);
        String sourceKeyBefore = str(source.getClass(), source, "getKey");
        String token = UUID.randomUUID().toString();
        JSONObject execution = new JSONObject()
            .put("token", token)
            .put("jobIdentity", System.identityHashCode(job))
            .put("contextIdentity", System.identityHashCode(context))
            .put("sourceObjectIdentity", System.identityHashCode(source))
            .put("sourceKey", sourceKeyBefore)
            .put("jobLevel", "created-parent")
            .put("boundBeforeInvocation", true);
        followUpJob = job;
        JSONObject freshness = deriveFollowUpFreshness(cancelExecutionJob, job,
            cancelExecutionContext, context, cancelExecutionSource, source,
            cancelExecutionSourceKey, sourceKeyBefore);
        evidence.put("followUpExecution", execution);
        boolean completed = false;
        Throwable failure = null;
        boolean jobClosed = false;
        String sourceKeyAfter = sourceKeyBefore;
        try {
            Object result = searchUnderContext(context, source, keyword);
            recordSearchResults(step, result, value);
            completed = true;
        } catch (Throwable error) {
            failure = error;
            evidence.put("followUpError", describe(error));
        } finally {
            try {
                requestCancel(members, job);
                jobClosed = isJobComplete(members, job);
            } catch (Throwable error) {
                evidence.put("followUpCloseError", describe(error));
            }
            sourceKeyAfter = str(source.getClass(), source, "getKey");
            execution.put("sourceKeyAfter", sourceKeyAfter)
                .put("jobClosed", jobClosed)
                .put("derivedFreshness", freshness)
                .put("resultRecorded", completed);
            if (jobClosed) followUpJob = null;
            boolean sameKeyAfter = sourceKeyBefore.equals(sourceKeyAfter);
            JSONObject followUp = new JSONObject()
                .put("jobIdentityFresh", freshness.optBoolean("jobIdentityFresh", false))
                .put("contextIdentityFresh",
                    freshness.optBoolean("contextIdentityFresh", false))
                .put("sameSourceObject", freshness.optBoolean("sameSourceObject", false))
                .put("sameSourceKey", freshness.optBoolean("sameSourceKey", false)
                    && sameKeyAfter)
                .put("jobLevel", "created-parent")
                .put("jobClosed", jobClosed)
                .put("sourceKey", sourceKeyBefore)
                .put("tokenPresent", true);
            value.put("followUp", followUp);
        }
        if (failure != null) throw failure;
        JSONObject followUp = value.optJSONObject("followUp");
        if (followUp == null || !(followUp.optBoolean("jobIdentityFresh")
                && followUp.optBoolean("contextIdentityFresh")
                && followUp.optBoolean("sameSourceObject")
                && followUp.optBoolean("sameSourceKey")
                && followUp.optBoolean("jobClosed"))) {
            throw new IncompleteStep("the follow-up execution identity is not proven: "
                + followUp);
        }
    }

    private void stageDetails(JSONObject step, Object source, JSONObject value) throws Throwable {
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        Class<?> bookClass = loader.loadClass("io.legado.app.data.entities.Book");
        String bookId = step.getString("book");
        Object book = require(books, bookId, "book");
        runSuspend(loader, continuation -> callSuspend(webBookClass, webBook,
            "getBookInfoAwait", 4,
            new Object[]{source, book, Boolean.TRUE}, continuation));
        value.put("book", bookId)
            .put("bookUrl", str(bookClass, book, "getBookUrl"))
            .put("name", str(bookClass, book, "getName"))
            .put("author", str(bookClass, book, "getAuthor"))
            .put("kind", nullToNull(call(book, "getKind")))
            .put("intro", nullToNull(call(book, "getIntro")))
            .put("coverUrl", nullToNull(call(book, "getCoverUrl")))
            .put("wordCount", nullToNull(call(book, "getWordCount")))
            .put("latestChapterTitle", nullToNull(call(book, "getLatestChapterTitle")))
            .put("tocUrl", str(bookClass, book, "getTocUrl"))
            .put("origin", str(bookClass, book, "getOrigin"));
    }

    private void stageToc(JSONObject step, Object source, JSONObject value) throws Throwable {
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        Class<?> chapterClass = loader.loadClass("io.legado.app.data.entities.BookChapter");
        String bookId = step.getString("book");
        Object book = require(books, bookId, "book");
        Object result = runSuspend(loader, continuation -> callSuspend(webBookClass, webBook,
            "getChapterListAwait", 4,
            new Object[]{source, book, Boolean.FALSE}, continuation));
        List<?> list = unwrapResult(result);
        if (list.isEmpty()) throw new IllegalStateException("table of contents is empty");
        JSONArray observed = new JSONArray();
        Map<String, Object> byUrl = new LinkedHashMap<>();
        for (Object chapter : list) {
            String url = str(chapterClass, chapter, "getUrl");
            byUrl.put(url, chapter);
            observed.put(new JSONObject()
                .put("index", ((Number) call(chapter, "getIndex")).intValue())
                .put("title", str(chapterClass, chapter, "getTitle"))
                .put("url", url)
                .put("tag", str(chapterClass, chapter, "getTag")));
        }
        chapters.put(bookId, byUrl);
        value.put("book", bookId).put("chapters", observed);
    }

    private void stageContent(JSONObject step, Object source, JSONObject value) throws Throwable {
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        String bookId = step.getString("book");
        Object book = require(books, bookId, "book");
        Map<String, Object> byUrl = chapters.get(bookId);
        if (byUrl == null) throw new IllegalStateException("no table of contents for " + bookId);
        String chapterUrl = step.getString("chapter");
        Object chapter = byUrl.get(chapterUrl);
        if (chapter == null) {
            throw new IllegalStateException("chapter " + chapterUrl
                + " is not in the table of contents of " + bookId);
        }
        Object text = runSuspend(loader, continuation -> callSuspend(webBookClass, webBook,
            "getContentAwait", 6,
            new Object[]{source, book, chapter, null, Boolean.FALSE}, continuation));
        value.put("book", bookId)
            .put("chapter", chapterUrl)
            .put("text", text == null ? "" : text.toString());
    }

    private void stepConnectionFailure(JSONObject step, JSONObject value) throws Throwable {
        Object source = require(sourcesById, step.getString("source"), "source");
        value.put("kind", "failure").put("source", step.getString("source"));
        failEndpoint.arm();
        boolean threw = false;
        Throwable thrown = null;
        try {
            search(source, step.getString("keyword"));
        } catch (Throwable error) {
            threw = true;
            thrown = error;
        }
        long acceptDeadline = System.currentTimeMillis() + 2000;
        while (failEndpoint.accepted() == 0 && System.currentTimeMillis() < acceptDeadline) {
            Thread.sleep(20);
        }
        JSONObject receipt = failEndpoint.report();
        int accepted = receipt.optInt("acceptedConnections", 0);
        value.put("acceptedConnections", accepted)
            .put("transportReconnects", Math.max(0, accepted - 1));
        if (!threw) {
            throw new IllegalStateException("the connection-failure row returned normally");
        }
        throw thrown;
    }

    // ---------------------------------------------------------- cancellation

    private void stepCancel(JSONObject step, JSONObject value, JSONObject evidence)
            throws Throwable {
        Object source = require(sourcesById, step.getString("source"), "source");
        String keyword = step.getString("keyword");
        StateSnapshot before;
        try {
            before = probeState(source);
        } catch (Throwable error) {
            throw new IncompleteStep("the state probe before cancellation is unresolved: "
                + describe(error));
        }
        cancelToken = UUID.randomUUID().toString();
        CancelMembers members;
        try {
            members = resolveCancelMembers();
        } catch (Throwable error) {
            evidence.put("entryError", describe(error));
            throw new IncompleteStep("the real cancellation entry is unresolved: "
                + describe(error));
        }
        cancelMembers = members;
        evidence.put("entry", members.report);
        Object job = members.newJob.invoke(null, new Object[]{null});
        Object context = members.plus.invoke(members.emptyContext, job);
        String sourceKey = str(source.getClass(), source, "getKey");
        cancelExecution = new JSONObject()
            .put("token", cancelToken)
            .put("jobIdentity", System.identityHashCode(job))
            .put("contextIdentity", System.identityHashCode(context))
            .put("sourceObjectIdentity", System.identityHashCode(source))
            .put("sourceKey", sourceKey)
            .put("jobLevel", "created-parent")
            .put("boundBeforeInvocation", true)
            .put("keyword", keyword);
        cancelExecutionJob = job;
        cancelExecutionContext = context;
        cancelExecutionSource = source;
        cancelExecutionSourceKey = sourceKey;
        evidence.put("execution", cancelExecution);
        activeCancelJob = job;
        final AtomicReference<Throwable> workerError = new AtomicReference<>();
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        Thread worker = new Thread(() -> {
            try {
                runBlockingWithContext(context, continuation -> callSuspend(webBookClass,
                    webBook, "searchBookAwait", 6,
                    new Object[]{source, keyword, Integer.valueOf(1), null, null},
                    continuation));
            } catch (Throwable error) {
                workerError.set(error);
            }
        }, "http-boundary-cancel");
        activeCancelWorker = worker;
        worker.start();
        value.put("kind", "cancel").put("source", step.getString("source"));
        boolean entered = replay.holdState.awaitEntered(10, TimeUnit.SECONDS);
        value.put("holdEntered", entered);
        if (!entered) {
            try {
                requestCancel(members, job);
            } catch (Throwable error) {
                evidence.put("missedEntryCancelError", describe(error));
            }
            replay.releaseHold();
            worker.join(3000);
            replay.holdState.awaitAbort(2, TimeUnit.SECONDS);
            boolean terminated = !worker.isAlive();
            boolean done = isJobComplete(members, job);
            if (terminated && done) {
                activeCancelJob = null;
                activeCancelWorker = null;
            }
            throw new IncompleteStep("the held request was not entered within 10s");
        }
        boolean cancelRequested = requestCancel(members, job);
        value.put("cancelRequested", cancelRequested);
        long cancelNanos = System.nanoTime();
        boolean aborted = replay.holdState.awaitAbort(10, TimeUnit.SECONDS);
        worker.join(10000);
        boolean terminated = !worker.isAlive();
        boolean jobInactive = isInactive(members, job);
        boolean jobCompleted = isJobComplete(members, job);
        boolean jobDone = jobInactive && jobCompleted;
        long quietWindow = corpus.getJSONObject("cancellation").getLong("quietWindowMs");
        Thread.sleep(quietWindow);
        Throwable workerFailure = workerError.get();
        String workerOutcome;
        if (workerFailure == null) {
            workerOutcome = "completed-normally";
        } else if (isCancellation(workerFailure)) {
            workerOutcome = "cancelled";
        } else {
            workerOutcome = "failure";
            evidence.put("workerError", describe(workerFailure));
        }
        JSONArray late = new JSONArray();
        synchronized (requests) {
            for (int index = 0; index < requests.length(); index++) {
                JSONObject request = requests.getJSONObject(index);
                if (!step.getString("id").equals(request.optString("owner", ""))) continue;
                if (request.optLong("receivedAtNanos", 0) > cancelNanos) {
                    late.put(new JSONObject()
                        .put("selector", request.optString("selector"))
                        .put("receivedAtNanos", request.optLong("receivedAtNanos")));
                }
            }
        }
        StateSnapshot after;
        try {
            after = probeState(source);
        } catch (Throwable error) {
            throw new IncompleteStep("the state probe after cancellation is unresolved: "
                + describe(error));
        }
        boolean valuesUnchanged = deepEqual(before.portable, after.portable);
        boolean databaseUnchanged = deepEqual(before.db, after.db);
        JSONObject derived = deriveCancelOutcome(workerOutcome, aborted, terminated,
            jobDone, late.length(), valuesUnchanged, databaseUnchanged);
        value.put("clientAborted", aborted)
            .put("workerTerminated", terminated)
            .put("jobInactive", jobInactive)
            .put("jobCompleted", jobCompleted)
            .put("jobDone", jobDone)
            .put("workerOutcome", workerOutcome)
            .put("lateRequests", late)
            .put("stateProbes", new JSONObject()
                .put("sourceValues", new JSONObject()
                    .put("before", before.portable.optJSONObject("sourceValues"))
                    .put("after", after.portable.optJSONObject("sourceValues")))
                .put("variable", new JSONObject()
                    .put("before", before.portable.optJSONObject("variable"))
                    .put("after", after.portable.optJSONObject("variable")))
                .put("unchanged", valuesUnchanged)
                .put("databaseUnchanged", databaseUnchanged))
            .put("execution", new JSONObject()
                .put("sourceKey", sourceKey)
                .put("jobLevel", "created-parent")
                .put("tokenPresent", true)
                .put("jobInactive", jobInactive)
                .put("jobCompleted", jobCompleted))
            .put("derivedOutcome", derived);
        evidence.put("dbProvenance", new JSONObject()
            .put("before", before.db)
            .put("after", after.db)
            .put("nativeTableSnapshotIsProvenance", true));
        evidence.put("worker", new JSONObject()
            .put("name", worker.getName())
            .put("id", worker.getId())
            .put("isActiveMemberUnresolved", members.isActive == null));
        if (terminated && jobDone) {
            activeCancelJob = null;
            activeCancelWorker = null;
        }
        if ("failure".equals(derived.optString("outcome"))) {
            if (workerFailure != null) throw workerFailure;
            throw new IllegalStateException("the cancelled search did not report a"
                + " cancellation: " + derived);
        }
        if (!"cancelled".equals(derived.optString("outcome"))) {
            throw new IncompleteStep("cancellation outcome is incomplete: " + derived);
        }
        throw new CancelledExecution();
    }

    /**
     * A typed portable snapshot for comparison plus an intrahost raw table snapshot for
     * provenance. A null value stays present:false, never the literal string "null"; an
     * unresolved getter or query throws so the row is incomplete instead of "unchanged".
     */
    private StateSnapshot probeState(Object source) throws Exception {
        StateSnapshot snapshot = new StateSnapshot();
        JSONObject values = new JSONObject();
        JSONArray keys = corpus.getJSONObject("cancellation").getJSONArray("stateProbes");
        for (int index = 0; index < keys.length(); index++) {
            String key = keys.getString(index);
            values.put(key, typedValue(call(source, "get", key)));
        }
        snapshot.portable.put("sourceValues", values)
            .put("variable", typedValue(call(source, "getVariable")));
        snapshot.db = dbCounts();
        return snapshot;
    }

    private static JSONObject typedValue(Object raw) throws JSONException {
        if (raw == null) {
            return new JSONObject().put("present", false);
        }
        return new JSONObject().put("present", true).put("value", String.valueOf(raw));
    }

    private JSONObject dbCounts() throws Exception {
        if (database == null) {
            throw new IllegalStateException("the database is not open; database state is"
                + " unresolved");
        }
        JSONObject counts = new JSONObject();
        JSONArray tables = corpus.getJSONObject("cancellation").getJSONArray("dbTables");
        for (int index = 0; index < tables.length(); index++) {
            String table = tables.getString(index);
            JSONArray rows = queryRows("select count(*) as n from " + table);
            if (rows.length() != 1) {
                throw new IllegalStateException("the database count for " + table
                    + " returned " + rows.length() + " rows");
            }
            Object cell = rows.getJSONObject(0).opt("n");
            if (cell == null || cell == JSONObject.NULL) {
                throw new IllegalStateException("the database count for " + table
                    + " is absent");
            }
            try {
                counts.put(table, Integer.parseInt(String.valueOf(cell)));
            } catch (NumberFormatException error) {
                throw new IllegalStateException("the database count for " + table
                    + " is not an integer: " + cell, error);
            }
        }
        return counts;
    }

    private CancelMembers resolveCancelMembers() throws Exception {
        Class<?> jobKt = loader.loadClass("kotlinx.coroutines.JobKt");
        Method newJob = null;
        for (Method candidate : jobKt.getMethods()) {
            if (!candidate.getName().equals("Job")) continue;
            if (candidate.getParameterCount() != 1) continue;
            if (!Modifier.isStatic(candidate.getModifiers())) continue;
            newJob = candidate;
        }
        if (newJob == null) {
            throw new IllegalStateException("kotlinx.coroutines.JobKt.Job(Job) is absent");
        }
        Class<?> contextClass = loader.loadClass("kotlin.coroutines.CoroutineContext");
        Method plus = contextClass.getMethod("plus", contextClass);
        Object empty = loader.loadClass("kotlin.coroutines.EmptyCoroutineContext")
            .getField("INSTANCE").get(null);
        Class<?> jobClass = loader.loadClass("kotlinx.coroutines.Job");
        Method cancel = null;
        for (Method candidate : jobClass.getMethods()) {
            if (!candidate.getName().equals("cancel")) continue;
            if (candidate.getParameterCount() != 1) continue;
            cancel = candidate;
        }
        Method isActive = null;
        Method isCompleted = null;
        for (Method candidate : jobClass.getMethods()) {
            if (candidate.getName().equals("isActive")
                    && candidate.getParameterCount() == 0) {
                isActive = candidate;
            }
            if (candidate.getName().equals("isCompleted")
                    && candidate.getParameterCount() == 0) {
                isCompleted = candidate;
            }
        }
        Method cancelDefault = null;
        if (cancel == null) {
            try {
                Class<?> defaults = loader.loadClass("kotlinx.coroutines.Job$DefaultImpls");
                for (Method candidate : defaults.getMethods()) {
                    if (!candidate.getName().equals("cancel$default")) continue;
                    if (candidate.getParameterCount() != 4) continue;
                    cancelDefault = candidate;
                }
            } catch (ClassNotFoundException absent) {
                // Reported below.
            }
        }
        if (cancel == null && cancelDefault == null) {
            throw new IllegalStateException("kotlinx.coroutines.Job.cancel is unresolved");
        }
        JSONObject report = new JSONObject()
            .put("newJob", newJob.toString())
            .put("plus", plus.toString())
            .put("cancel", cancel == null ? JSONObject.NULL : cancel.toString())
            .put("cancelDefault", cancelDefault == null
                ? JSONObject.NULL : cancelDefault.toString())
            .put("isActive", isActive == null ? JSONObject.NULL : isActive.toString())
            .put("isCompleted", isCompleted == null
                ? JSONObject.NULL : isCompleted.toString())
            .put("runBlocking", runBlockingMethod().toString());
        return new CancelMembers(newJob, plus, empty, cancel, cancelDefault, isActive,
            isCompleted, report);
    }

    private static boolean isInactive(CancelMembers members, Object job) {
        if (members == null || members.isActive == null || job == null) return false;
        try {
            return !((Boolean) members.isActive.invoke(job)).booleanValue();
        } catch (Throwable error) {
            return false;
        }
    }

    /**
     * A created-parent job is only complete when the frozen library reports both
     * isActive=false and isCompleted=true; neither flag alone proves the child work
     * finished. An unresolved member is treated as unproved, never as completion.
     */
    private static boolean isJobComplete(CancelMembers members, Object job) {
        if (members == null || job == null || members.isActive == null
                || members.isCompleted == null) {
            return false;
        }
        try {
            boolean active = ((Boolean) members.isActive.invoke(job)).booleanValue();
            boolean completed = ((Boolean) members.isCompleted.invoke(job)).booleanValue();
            return !active && completed;
        } catch (Throwable error) {
            return false;
        }
    }

    /** Signals every owned created-parent job without joining anything. */
    private boolean signalOwnedJobs() {
        boolean ok = true;
        if (activeCancelJob != null && cancelMembers != null) {
            try {
                requestCancel(cancelMembers, activeCancelJob);
            } catch (Throwable error) {
                ok = false;
            }
        }
        if (followUpJob != null && cancelMembers != null) {
            try {
                requestCancel(cancelMembers, followUpJob);
            } catch (Throwable error) {
                ok = false;
            }
        }
        return ok;
    }

    /**
     * Awaits every owned worker/job after the gates are free. A worker that is still
     * alive or a job that is still active keeps its handle, so cleanup can preserve the
     * owned residue instead of deleting beneath an unproved termination.
     */
    private boolean awaitOwnedJobs() {
        boolean ok = true;
        if (activeCancelWorker != null) {
            try {
                activeCancelWorker.join(5000);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            }
            if (activeCancelWorker.isAlive()) ok = false;
        }
        if (activeCancelJob != null && !isJobComplete(cancelMembers, activeCancelJob)) {
            ok = false;
        }
        if (followUpJob != null && !isJobComplete(cancelMembers, followUpJob)) {
            ok = false;
        }
        if (ok) {
            activeCancelJob = null;
            activeCancelWorker = null;
            followUpJob = null;
        }
        return ok;
    }

    private boolean requestCancel(CancelMembers members, Object job) throws Exception {
        try {
            if (members.cancel != null) {
                members.cancel.invoke(job, new Object[]{null});
            } else {
                members.cancelDefault.invoke(null, job, null, Integer.valueOf(1), null);
            }
            return true;
        } catch (InvocationTargetException error) {
            throw asException(error.getCause());
        }
    }

    private Method runBlockingMethod() throws Exception {
        if (runBlockingMethod != null) return runBlockingMethod;
        Class<?> builders = loader.loadClass("kotlinx.coroutines.BuildersKt");
        for (Method candidate : builders.getMethods()) {
            if (!candidate.getName().equals("runBlocking")) continue;
            if (candidate.getParameterCount() != 2) continue;
            if (candidate.getParameterTypes()[1].getName()
                    .equals("kotlin.jvm.functions.Function2")) {
                runBlockingMethod = candidate;
            }
        }
        if (runBlockingMethod == null) {
            throw new IllegalStateException("the two-argument runBlocking is absent");
        }
        return runBlockingMethod;
    }

    private Object runBlockingWithContext(Object context, SuspendCall call) throws Throwable {
        Class<?> function2 = loader.loadClass("kotlin.jvm.functions.Function2");
        Object block = Proxy.newProxyInstance(loader, new Class<?>[]{function2},
            (proxy, method, args) -> {
                switch (method.getName()) {
                    case "invoke":
                        return call.run(args[1]);
                    case "toString":
                        return "http-boundary-oracle-block";
                    case "hashCode":
                        return System.identityHashCode(proxy);
                    case "equals":
                        return args != null && args.length == 1 && proxy == args[0];
                    default:
                        return null;
                }
            });
        try {
            return runBlockingMethod().invoke(null, context, block);
        } catch (InvocationTargetException error) {
            throw error.getCause();
        }
    }

    // ------------------------------------------------------------- checks

    private int declaredTotal() {
        int total = 0;
        for (Integer value : declaredStepRequests.values()) total += value.intValue();
        return total;
    }

    /**
     * Request completeness is checked over the whole final trace: declared total, every
     * causal owner, required raw fields/types, honest terminals, headers and the one
     * permitted negative omission. Per-owner slices alone are not sufficient.
     */
    /**
     * Reads the declared User-Agent from the authored header field, never from a
     * serialized source container. Static headers are parsed as JSON; the two script
     * header forms are read as their declared JSON.stringify object literal without
     * executing the script. Missing, wrong or non-string values return null.
     */
    private static final Pattern SCRIPT_UA = Pattern.compile(
        "(?i)['\"]User-Agent['\"]\\s*:\\s*['\"]([^'\"]*)['\"]");

    private static String declaredHeaderUserAgent(String header) throws JSONException {
        if (header == null) return null;
        String text = header.trim();
        if (text.startsWith("@js:")) return scriptHeaderUserAgent(text.substring(4));
        if (text.startsWith("<js>")) {
            int end = text.lastIndexOf('<');
            if (end < 0) return null;
            return scriptHeaderUserAgent(text.substring(4, end));
        }
        JSONObject parsed = new JSONObject(text);
        Iterator<String> names = parsed.keys();
        while (names.hasNext()) {
            String name = names.next();
            if (!name.equalsIgnoreCase("User-Agent")) continue;
            Object value = parsed.opt(name);
            if (value == null || value == JSONObject.NULL) return null;
            return value instanceof String ? (String) value : null;
        }
        return null;
    }

    private static String scriptHeaderUserAgent(String script) {
        int call = script.indexOf("JSON.stringify(");
        if (call < 0) return null;
        int start = script.indexOf('{', call);
        int end = script.lastIndexOf('}');
        if (start < 0 || end <= start) return null;
        Matcher matcher = SCRIPT_UA.matcher(script.substring(start + 1, end));
        return matcher.find() ? matcher.group(1) : null;
    }

    private JSONObject reportCheck(String area) throws Exception {
        if ("request".equals(area)) {
            if (requestCheckValue != null) return requestCheckValue;
            return corpusIndexed ? requestCheck() : notEvaluated("request");
        }
        if (observationCheckValue != null) return observationCheckValue;
        return corpusIndexed ? observationCheck() : notEvaluated("observation");
    }

    private static JSONObject notEvaluated(String area) throws JSONException {
        return new JSONObject().put("match", false)
            .put("notEvaluated", true)
            .put("status", "not-evaluated")
            .put("reason", "setup did not complete before the " + area
                + " indexes were built");
    }

    private JSONArray notEvaluatedAreas() throws JSONException {
        JSONArray areas = new JSONArray();
        if (requestCheckValue == null && !corpusIndexed) areas.put("requestCheck");
        if (observationCheckValue == null && !corpusIndexed) areas.put("observationCheck");
        if (structural == null) areas.put("structural");
        return areas;
    }

    private JSONObject requestCheck() throws Exception {
        JSONArray steps = corpus.getJSONArray("steps");
        JSONArray actual = snapshot(requests);
        JSONArray rows = new JSONArray();
        boolean stepMatch = true;
        String cancelStep = corpus.getJSONObject("cancellation").getString("step");
        Set<Integer> indices = new LinkedHashSet<>();
        JSONArray duplicateIndices = new JSONArray();
        JSONArray fieldProblems = new JSONArray();
        JSONArray terminalProblems = new JSONArray();
        JSONArray ownerless = new JSONArray();
        JSONArray unknownOwners = new JSONArray();
        for (int index = 0; index < actual.length(); index++) {
            JSONObject request = actual.getJSONObject(index);
            int requestIndex = request.optInt("index", -1);
            if (requestIndex <= 0 || !indices.add(Integer.valueOf(requestIndex))) {
                duplicateIndices.put(requestIndex);
            }
            JSONArray problems;
            try {
                problems = requestProblems(request, cancelStep);
            } catch (Throwable error) {
                problems = new JSONArray();
                problems.put("request record cannot be validated: " + describe(error));
            }
            if (problems.length() > 0) {
                JSONObject typed = new JSONObject()
                    .put("index", requestIndex)
                    .put("selector", request.optString("selector"))
                    .put("problems", problems);
                boolean terminalOnly = true;
                for (int slot = 0; slot < problems.length(); slot++) {
                    if (!problems.getString(slot).startsWith("terminal ")) terminalOnly = false;
                }
                if (terminalOnly) {
                    terminalProblems.put(typed);
                } else {
                    fieldProblems.put(typed);
                }
            }
            if (request.isNull("owner")) {
                ownerless.put(new JSONObject().put("index", requestIndex)
                    .put("selector", request.optString("selector")));
            } else {
                String owner = request.optString("owner", "");
                if (!declaredStepRequests.containsKey(owner)) {
                    unknownOwners.put(new JSONObject().put("index", requestIndex)
                        .put("owner", owner));
                }
            }
        }
        for (int index = 0; index < steps.length(); index++) {
            JSONObject step = steps.getJSONObject(index);
            String id = step.getString("id");
            JSONObject spec = step.getJSONObject("requests");
            JSONArray ordered = spec.optJSONArray("ordered");
            JSONObject batch = spec.optJSONObject("batch");
            List<String> expectedOrdered = new ArrayList<>();
            if (ordered != null) {
                for (int slot = 0; slot < ordered.length(); slot++) {
                    expectedOrdered.add(selectorOf(responseById.get(ordered.getString(slot))));
                }
            }
            List<String> expectedBatch = new ArrayList<>();
            if (batch != null) {
                JSONArray members = batch.getJSONArray("members");
                for (int slot = 0; slot < members.length(); slot++) {
                    expectedBatch.add(selectorOf(responseById.get(members.getString(slot))));
                }
            }
            List<JSONObject> actualRows = rowsByOwner(actual, id);
            JSONArray actualSelectors = new JSONArray();
            for (JSONObject row : actualRows) actualSelectors.put(row.optString("selector"));
            boolean countOk = actualRows.size() == expectedOrdered.size() + expectedBatch.size();
            boolean orderOk = true;
            for (int slot = 0; slot < expectedOrdered.size(); slot++) {
                if (slot >= actualRows.size()
                        || !expectedOrdered.get(slot).equals(
                            actualRows.get(slot).optString("selector"))) {
                    orderOk = false;
                }
            }
            boolean batchOk = true;
            if (batch != null) {
                List<String> actualTail = new ArrayList<>();
                for (int slot = expectedOrdered.size(); slot < actualRows.size(); slot++) {
                    actualTail.add(actualRows.get(slot).optString("selector"));
                }
                batchOk = matchesMultiset(actualTail, expectedBatch);
            }
            JSONArray headerProblems = new JSONArray();
            JSONArray forbidden = new JSONArray();
            JSONObject required = step.optJSONObject("requiredHeaders");
            JSONArray stepForbidden = step.optJSONArray("forbiddenHeaders");
            for (JSONObject row : actualRows) {
                JSONObject headers = row.optJSONObject("headers");
                if (required != null) {
                    if (headers == null) {
                        headerProblems.put(new JSONObject()
                            .put("step", id)
                            .put("index", row.optInt("index"))
                            .put("header", "*")
                            .put("expected", "required headers object")
                            .put("actual", JSONObject.NULL));
                    } else {
                        Iterator<String> names = required.keys();
                        while (names.hasNext()) {
                            String name = names.next();
                            String expected = required.getString(name);
                            if (!headers.has(name)) {
                                headerProblems.put(new JSONObject()
                                    .put("step", id)
                                    .put("index", row.optInt("index"))
                                    .put("header", name)
                                    .put("expected", expected)
                                    .put("actual", JSONObject.NULL));
                            } else {
                                String observed = headers.optString(name, "");
                                if (!expected.equals(observed)) {
                                    headerProblems.put(new JSONObject()
                                        .put("step", id)
                                        .put("index", row.optInt("index"))
                                        .put("header", name)
                                        .put("expected", expected)
                                        .put("actual", observed));
                                }
                            }
                        }
                    }
                }
                if (stepForbidden != null) {
                    for (int slot = 0; slot < stepForbidden.length(); slot++) {
                        String name = stepForbidden.getString(slot).toLowerCase(Locale.US);
                        if (headers == null || headers.has(name)) {
                            forbidden.put(new JSONObject()
                                .put("step", id)
                                .put("index", row.optInt("index"))
                                .put("header", name)
                                .put("headersMissing", headers == null));
                        }
                    }
                }
            }
            boolean rowOk = countOk && orderOk && batchOk && headerProblems.length() == 0
                && forbidden.length() == 0;
            stepMatch &= rowOk;
            rows.put(new JSONObject()
                .put("id", id)
                .put("expectedOrdered", toArray(expectedOrdered))
                .put("expectedBatch", toArray(expectedBatch))
                .put("actual", actualSelectors)
                .put("countMatch", countOk)
                .put("orderMatch", orderOk)
                .put("batchMatch", batchOk)
                .put("headerProblems", headerProblems)
                .put("forbidden", forbidden)
                .put("match", rowOk));
        }
        JSONArray globalForbidden = new JSONArray();
        JSONArray names = corpus.getJSONObject("requestChecks").getJSONArray("forbiddenHeaders");
        for (int index = 0; index < actual.length(); index++) {
            JSONObject headers = actual.getJSONObject(index).optJSONObject("headers");
            if (headers == null) {
                globalForbidden.put(new JSONObject()
                    .put("index", actual.getJSONObject(index).optInt("index"))
                    .put("header", "*")
                    .put("headersMissing", true));
                continue;
            }
            for (int nameIndex = 0; nameIndex < names.length(); nameIndex++) {
                String name = names.getString(nameIndex).toLowerCase(Locale.US);
                if (headers.has(name)) {
                    globalForbidden.put(new JSONObject()
                        .put("index", actual.getJSONObject(index).optInt("index"))
                        .put("header", name));
                }
            }
        }
        boolean totalMatch = actual.length() == declaredTotal();
        boolean ownersAccounted = ownerless.length() == 0 && unknownOwners.length() == 0
            && duplicateIndices.length() == 0;
        JSONObject omission = negativeOmissionCheck();
        boolean intendedOmission = omission.optBoolean("intended", false);
        int otherUnmatched = omission.optInt("otherUnmatched", 0);
        boolean unmatchedPolicyOk = negativeMode
            ? intendedOmission && otherUnmatched == 0
            : unmatched.length() == 0;
        boolean ok = stepMatch && totalMatch && ownersAccounted
            && fieldProblems.length() == 0 && terminalProblems.length() == 0
            && unmatchedPolicyOk && globalForbidden.length() == 0
            && serverErrors.length() == 0;
        return new JSONObject()
            .put("steps", rows)
            .put("declaredResponses", corpus.getJSONArray("responses").length())
            .put("declaredRequests", declaredTotal())
            .put("actualRequests", actual.length())
            .put("totalMatch", totalMatch)
            .put("ownerless", ownerless)
            .put("unknownOwners", unknownOwners)
            .put("duplicateIndices", duplicateIndices)
            .put("fieldProblems", fieldProblems)
            .put("terminalProblems", terminalProblems)
            .put("unmatched", unmatched.length())
            .put("intendedOmission", intendedOmission)
            .put("otherUnmatched", otherUnmatched)
            .put("unmatchedPolicyOk", unmatchedPolicyOk)
            .put("negativeOmission", omission)
            .put("serverErrors", serverErrors.length())
            .put("forbiddenHeaders", globalForbidden)
            .put("match", ok);
    }

    private static void requireField(JSONObject request, String name, Class<?> type,
            JSONArray problems) throws JSONException {
        if (!request.has(name) || request.isNull(name)) {
            problems.put(name + " is missing or null");
            return;
        }
        Object value = request.get(name);
        if (!type.isInstance(value)) {
            problems.put(name + " has type " + value.getClass().getName()
                + ", expected " + type.getSimpleName());
        }
    }

    private JSONArray requestProblems(JSONObject request, String cancelStep) throws Exception {
        JSONArray problems = new JSONArray();
        requireField(request, "index", Number.class, problems);
        requireField(request, "owner", String.class, problems);
        requireField(request, "family", String.class, problems);
        requireField(request, "listener", String.class, problems);
        requireField(request, "stage", String.class, problems);
        requireField(request, "selector", String.class, problems);
        requireField(request, "method", String.class, problems);
        requireField(request, "path", String.class, problems);
        requireField(request, "rawQuery", String.class, problems);
        requireField(request, "target", String.class, problems);
        requireField(request, "query", JSONObject.class, problems);
        requireField(request, "headerLines", JSONArray.class, problems);
        requireField(request, "body", String.class, problems);
        requireField(request, "headers", JSONObject.class, problems);
        requireField(request, "outcome", String.class, problems);
        requireField(request, "terminal", String.class, problems);
        requireField(request, "attempt", Number.class, problems);
        requireField(request, "attemptKind", String.class, problems);
        requireField(request, "receivedAtNanos", Number.class, problems);
        requireField(request, "respondedAtNanos", Number.class, problems);
        requireField(request, "sentAtNanos", Number.class, problems);
        requireField(request, "sendSequence", Number.class, problems);
        requireField(request, "status", Number.class, problems);
        requireField(request, "bodyLength", Number.class, problems);
        requireField(request, "bodySha256", String.class, problems);
        if (!request.has("declaredResponse")) {
            problems.put("declaredResponse is missing");
        } else if (!request.isNull("declaredResponse")
                && !(request.get("declaredResponse") instanceof String)) {
            problems.put("declaredResponse has an invalid type");
        }
        if (problems.length() > 0) return problems;
        String selector = request.getString("selector");
        String owner = request.getString("owner");
        if (!declaredStepRequests.containsKey(owner)) {
            problems.put("owner " + owner + " is not a declared step");
        }
        Owner declaredOwner = selectorOwners.get(selector);
        boolean declaredOmission = negativeMode && negativeBlock != null
            && selector.equals(negativeBlock.optString("selector", ""));
        if (declaredOwner == null) {
            if (!declaredOmission) problems.put("selector " + selector + " is not declared");
        } else if (!declaredOwner.step.equals(owner)) {
            problems.put("selector " + selector + " is owned by " + declaredOwner.step
                + ", request says " + owner);
        }
        String method = request.getString("method");
        String path = request.getString("path");
        String rawQuery = request.getString("rawQuery");
        String target = request.getString("target");
        String computedSelector = method + " " + path + "?" + rawQuery;
        if (!selector.equals(computedSelector)) {
            problems.put("method/path/rawQuery do not form the selector");
        }
        String expectedTarget = rawQuery.isEmpty() ? path : path + "?" + rawQuery;
        if (!target.equals(expectedTarget)) {
            problems.put("target does not match path/rawQuery");
        }
        JSONObject query = request.getJSONObject("query");
        if (!deepEqual(query, new JSONObject(decodeQuery(rawQuery)))) {
            problems.put("query does not decode the raw query");
        }
        JSONArray headerLines = request.getJSONArray("headerLines");
        for (int slot = 0; slot < headerLines.length(); slot++) {
            if (!(headerLines.opt(slot) instanceof String)) {
                problems.put("headerLines entry " + slot + " is not a string");
            }
        }
        if (!request.has("cohort")) {
            problems.put("cohort is missing");
        } else if (declaredOwner != null) {
            String cohort = declaredOwner.cohort;
            if (cohort == null) {
                if (!request.isNull("cohort")) {
                    problems.put("cohort must be explicit null for a singleton owner");
                }
            } else if (request.isNull("cohort")
                    || !(request.get("cohort") instanceof String)
                    || !cohort.equals(request.getString("cohort"))) {
                problems.put("cohort does not match the declared owner");
            }
        } else if (!request.isNull("cohort")
                && !(request.get("cohort") instanceof String)) {
            problems.put("cohort has an invalid type");
        }
        if (declaredOwner != null) {
            if (!declaredOwner.family.equals(request.getString("family"))) {
                problems.put("family does not match the declared owner");
            }
            String expectedResponse = selectorResponseIds.get(selector);
            String selected = request.isNull("declaredResponse")
                ? null : request.getString("declaredResponse");
            boolean omission = negativeMode && negativeBlock != null
                && selector.equals(negativeBlock.optString("selector", ""))
                && "omitted-unmatched".equals(request.optString("terminal", ""))
                && selected == null;
            if (omission) {
                if (expectedResponse == null
                        || !expectedResponse.equals(negativeBlock.optString("drop", ""))) {
                    problems.put("the native omission does not select the declared drop");
                }
            } else if (expectedResponse == null || !expectedResponse.equals(selected)) {
                problems.put("declaredResponse is not the declaration selected by the"
                    + " selector");
            }
        }
        byte[] bodyBytes = request.getString("body").getBytes(StandardCharsets.UTF_8);
        if (request.getInt("bodyLength") != bodyBytes.length) {
            problems.put("bodyLength does not match the body bytes");
        }
        if (!sha256(bodyBytes).equals(request.getString("bodySha256"))) {
            problems.put("bodySha256 does not match the body");
        }
        String attemptKind = request.getString("attemptKind");
        if (!new LinkedHashSet<>(Arrays.asList("initial", "source-status-retry",
                "transport-reconnect")).contains(attemptKind)) {
            problems.put("unknown attemptKind " + attemptKind);
        }
        if (request.getInt("attempt") < 1) problems.put("attempt is not positive");
        String terminal = request.getString("terminal");
        long respondedAt = request.getLong("respondedAtNanos");
        long sentAt = request.getLong("sentAtNanos");
        int status = request.getInt("status");
        int sendSequence = request.getInt("sendSequence");
        if (!terminal.equals(request.optString("outcome", ""))) {
            problems.put("terminal " + terminal + " disagrees with outcome "
                + request.optString("outcome", ""));
        }
        switch (terminal) {
            case "responded":
            case "omitted-unmatched":
            case "rejected-after-shutdown":
                if (respondedAt <= 0) {
                    problems.put("terminal " + terminal + " has no response completion");
                }
                if (sentAt <= 0) {
                    problems.put("terminal " + terminal + " has no send time");
                }
                if (sendSequence <= 0) {
                    problems.put("terminal " + terminal + " has no send sequence");
                }
                if (status <= 0) {
                    problems.put("terminal " + terminal + " has no status");
                }
                break;
            case "client-aborted":
                if (respondedAt != -1 || sentAt != -1 || sendSequence != -1 || status != -1) {
                    problems.put("terminal client-aborted carries a response fact");
                }
                if (!owner.equals(cancelStep)) {
                    problems.put("terminal client-aborted is not owned by the cancel step");
                }
                break;
            case "received":
            case "held":
                problems.put("terminal " + terminal + " is not a terminal response");
                break;
            case "hold-released-at-teardown":
            case "hold-window-expired":
                problems.put("terminal " + terminal + " is not an accepted terminal");
                break;
            default:
                problems.put("unknown terminal " + terminal);
        }
        if ("rejected-after-shutdown".equals(terminal)) {
            problems.put("terminal rejected-after-shutdown is not an accepted request");
        }
        String declaredResponse = request.isNull("declaredResponse")
            ? null : request.getString("declaredResponse");
        if ("responded".equals(terminal) && declaredResponse == null) {
            problems.put("terminal responded has no declared response");
        }
        if ("omitted-unmatched".equals(terminal)) {
            if (!negativeMode || negativeBlock == null) {
                problems.put("terminal omitted-unmatched outside the negative control");
            } else {
                if (!selector.equals(negativeBlock.optString("selector", ""))) {
                    problems.put("terminal omitted-unmatched is not the declared omission");
                }
                if (!owner.equals(negativeBlock.optString("expectedOwner", ""))) {
                    problems.put("terminal omitted-unmatched owner is not the declared owner");
                }
                if (status != negativeBlock.optInt("expectedStatus", 404)) {
                    problems.put("terminal omitted-unmatched status is not the declared"
                        + " status");
                }
            }
            if (declaredResponse != null) {
                problems.put("terminal omitted-unmatched carries a declared response");
            }
        }
        return problems;
    }

    private JSONObject negativeOmissionCheck() throws JSONException {
        JSONArray entries = new JSONArray();
        int other = 0;
        String selector = negativeBlock == null ? ""
            : negativeBlock.optString("selector", "");
        String owner = negativeBlock == null ? ""
            : negativeBlock.optString("expectedOwner", "");
        String terminal = negativeBlock == null ? ""
            : negativeBlock.optString("expectedTerminal", "");
        int status = negativeBlock == null ? -1
            : negativeBlock.optInt("expectedStatus", -1);
        for (int index = 0; index < unmatched.length(); index++) {
            JSONObject entry = unmatched.getJSONObject(index);
            boolean intended = negativeMode
                && selector.equals(entry.optString("selector"))
                && owner.equals(entry.optString("owner"))
                && terminal.equals(entry.optString("terminal"))
                && entry.optInt("status", -1) == status
                && entry.isNull("declaredResponse");
            entries.put(new JSONObject()
                .put("selector", entry.optString("selector"))
                .put("owner", entry.isNull("owner") ? JSONObject.NULL
                    : entry.optString("owner"))
                .put("terminal", entry.optString("terminal"))
                .put("intended", intended));
            if (!intended) other++;
        }
        boolean intendedOk = negativeMode && unmatched.length() == 1 && other == 0;
        return new JSONObject().put("intended", intendedOk)
            .put("otherUnmatched", other)
            .put("entries", entries);
    }

    private JSONObject observationCheck() throws Exception {
        JSONArray steps = corpus.getJSONArray("steps");
        JSONArray declared = new JSONArray();
        JSONArray actual = new JSONArray();
        Set<String> declaredSet = new LinkedHashSet<>();
        Set<String> actualSet = new LinkedHashSet<>();
        JSONArray duplicates = new JSONArray();
        for (int index = 0; index < steps.length(); index++) {
            String id = steps.getJSONObject(index).getString("id");
            declared.put(id);
            declaredSet.add(id);
        }
        synchronized (observations) {
            for (int index = 0; index < observations.length(); index++) {
                String id = observations.getJSONObject(index).getString("id");
                actual.put(id);
                if (!actualSet.add(id)) duplicates.put(id);
            }
        }
        JSONArray missing = new JSONArray();
        JSONArray extra = new JSONArray();
        for (String id : declaredSet) if (!actualSet.contains(id)) missing.put(id);
        for (String id : actualSet) if (!declaredSet.contains(id)) extra.put(id);
        boolean ordered = declared.length() == actual.length();
        for (int index = 0; ordered && index < declared.length(); index++) {
            if (!declared.getString(index).equals(actual.getString(index))) ordered = false;
        }
        JSONArray outcomeMismatches = new JSONArray();
        JSONArray requestCountMismatches = new JSONArray();
        JSONArray shapeMismatches = new JSONArray();
        String cancelStep = corpus.getJSONObject("cancellation").getString("step");
        String followUpStep = corpus.getJSONObject("cancellation")
            .getString("followUpStep");
        for (int index = 0; index < steps.length(); index++) {
            JSONObject step = steps.getJSONObject(index);
            String id = step.getString("id");
            JSONObject row = rowById(id);
            if (row == null) continue;
            String expected = step.getString("expectedOutcome");
            String observed = row.optString("outcome", "");
            String category = row.isNull("category") ? null : row.optString("category");
            boolean categoryOk = true;
            if ("failure".equals(expected)) {
                categoryOk = step.getString("expectedCategory").equals(category);
            } else if ("cancelled".equals(expected)) {
                categoryOk = "cancellation".equals(category);
            }
            if (!expected.equals(observed) || !categoryOk) {
                outcomeMismatches.put(new JSONObject()
                    .put("id", id)
                    .put("expected", expected)
                    .put("actual", observed)
                    .put("actualCategory", category == null ? JSONObject.NULL : category));
            }
            int expectedRequests = declaredStepRequests.get(id).intValue();
            int actualRequests = row.getJSONArray("requests").length();
            if (actualRequests != expectedRequests) {
                requestCountMismatches.put(new JSONObject()
                    .put("id", id)
                    .put("expected", expectedRequests)
                    .put("actual", actualRequests));
            }
            if ("headerMap".equals(step.optString("action", ""))) {
                JSONObject arities = row.optJSONObject("value") == null ? null
                    : row.getJSONObject("value").optJSONObject("arities");
                boolean shapeOk = arities != null;
                for (String arity : new String[]{"zero", "falseArity", "trueArity"}) {
                    JSONObject measured = arities == null ? null
                        : arities.optJSONObject(arity);
                    if (measured == null || !(measured.opt("returned") instanceof Boolean)) {
                        shapeOk = false;
                    } else if (measured.getBoolean("returned")
                            && measured.optJSONArray("value") == null) {
                        shapeOk = false;
                    }
                }
                if (!shapeOk) {
                    shapeMismatches.put(new JSONObject().put("id", id)
                        .put("problem", "the three script arities are not measured"));
                }
            }
            if (id.equals(cancelStep)) {
                JSONObject cancelValue = row.optJSONObject("value");
                JSONObject derived = cancelValue == null ? null
                    : cancelValue.optJSONObject("derivedOutcome");
                if (derived == null || !"cancelled".equals(
                        derived.optString("outcome", ""))
                        || cancelValue == null
                        || !cancelValue.optBoolean("jobCompleted", false)
                        || !cancelValue.optBoolean("jobDone", false)) {
                    shapeMismatches.put(new JSONObject().put("id", id)
                        .put("problem", "the measured cancellation outcome or job"
                            + " completion is not proved"));
                }
            }
            if (id.equals(followUpStep)) {
                JSONObject followValue = row.optJSONObject("value");
                JSONObject follow = followValue == null ? null
                    : followValue.optJSONObject("followUp");
                boolean followOk = follow != null
                    && follow.optBoolean("jobIdentityFresh", false)
                    && follow.optBoolean("contextIdentityFresh", false)
                    && follow.optBoolean("sameSourceObject", false)
                    && follow.optBoolean("sameSourceKey", false)
                    && follow.optBoolean("jobClosed", false);
                if (!followOk) {
                    shapeMismatches.put(new JSONObject().put("id", id)
                        .put("problem", "the follow-up execution is not bound/proven"));
                }
            }
        }
        boolean match = missing.length() == 0 && extra.length() == 0
            && duplicates.length() == 0 && ordered
            && outcomeMismatches.length() == 0 && requestCountMismatches.length() == 0
            && shapeMismatches.length() == 0;
        return new JSONObject()
            .put("declared", declared)
            .put("actual", actual)
            .put("missing", missing)
            .put("extra", extra)
            .put("duplicates", duplicates)
            .put("ordered", ordered)
            .put("outcomeMismatches", outcomeMismatches)
            .put("requestCountMismatches", requestCountMismatches)
            .put("shapeMismatches", shapeMismatches)
            .put("match", match);
    }

    private JSONObject evaluateSuccess() throws Exception {
        JSONArray reasons = new JSONArray();
        if (!requestCheckValue.optBoolean("match", false)) {
            reasons.put("the final request trace is not complete; total="
                + requestCheckValue.optInt("actualRequests", -1)
                + "/" + requestCheckValue.optInt("declaredRequests", -1)
                + " ownerless=" + requestCheckValue.optJSONArray("ownerless").length()
                + " fieldProblems=" + requestCheckValue.optJSONArray("fieldProblems").length()
                + " terminalProblems="
                + requestCheckValue.optJSONArray("terminalProblems").length());
        }
        if (serverErrors.length() != 0) {
            reasons.put("serverErrors: " + serverErrors.length());
        }
        if (!observationCheckValue.optBoolean("match", false)) {
            reasons.put("an observation id, order, outcome, count or shape differs");
        }
        if (structural == null || !structural.optBoolean("match", false)) {
            reasons.put("the declared structural model is not derived from the corpus");
        }
        if (!cohortsEntered) {
            reasons.put("a declared cohort was never entered");
        }
        if (!failEndpointOk) {
            reasons.put("the failure endpoint saw unexpected activity or did not close");
        }
        if (failEndpoint == null || failEndpoint.accepted() == 0) {
            reasons.put("the connection-failure request never reached the owned endpoint");
        }
        JSONObject cancelRow = rowById(corpus.getJSONObject("cancellation").getString("step"));
        boolean cancellationOk = false;
        if (cancelRow != null) {
            JSONObject cancelValue = cancelRow.optJSONObject("value");
            if (cancelValue != null) {
                JSONArray lateRequests = cancelValue.optJSONArray("lateRequests");
                JSONObject stateProbes = cancelValue.optJSONObject("stateProbes");
                JSONObject execution = cancelValue.optJSONObject("execution");
                JSONObject derived = cancelValue.optJSONObject("derivedOutcome");
                cancellationOk = "cancelled".equals(cancelRow.optString("outcome"))
                    && cancelValue.optBoolean("holdEntered", false)
                    && cancelValue.optBoolean("clientAborted", false)
                    && cancelValue.optBoolean("workerTerminated", false)
                    && cancelValue.optBoolean("jobInactive", false)
                    && cancelValue.optBoolean("jobCompleted", false)
                    && cancelValue.optBoolean("jobDone", false)
                    && lateRequests != null && lateRequests.length() == 0
                    && stateProbes != null && stateProbes.optBoolean("unchanged", false)
                    && stateProbes.optBoolean("databaseUnchanged", false)
                    && execution != null && "created-parent".equals(
                        execution.optString("jobLevel", ""))
                    && derived != null && "cancelled".equals(
                        derived.optString("outcome", ""));
            }
        }
        if (!cancellationOk) {
            reasons.put("the cancellation row is incomplete or its receipts are missing");
        }
        JSONObject followUpRow = rowById(corpus.getJSONObject("cancellation")
            .getString("followUpStep"));
        boolean followUpOk = false;
        if (followUpRow != null) {
            JSONObject followValue = followUpRow.optJSONObject("value");
            JSONObject follow = followValue == null ? null
                : followValue.optJSONObject("followUp");
            followUpOk = follow != null
                && follow.optBoolean("jobIdentityFresh", false)
                && follow.optBoolean("contextIdentityFresh", false)
                && follow.optBoolean("sameSourceObject", false)
                && follow.optBoolean("sameSourceKey", false)
                && follow.optBoolean("jobClosed", false);
        }
        if (!followUpOk) {
            reasons.put("the post-cancellation same-source execution is not bound/proven");
        }
        synchronized (observations) {
            for (int index = 0; index < observations.length(); index++) {
                JSONObject row = observations.getJSONObject(index);
                JSONObject value = row.optJSONObject("value");
                if (value == null || !value.has("scheduleComplete")) continue;
                if (!value.optBoolean("scheduleComplete", false)) {
                    reasons.put("incomplete-schedule: " + row.optString("id"));
                }
            }
        }
        return new JSONObject().put("ok", reasons.length() == 0).put("reasons", reasons);
    }

    private String joinReasons(JSONArray reasons) throws JSONException {
        StringBuilder text = new StringBuilder();
        for (int index = 0; index < reasons.length(); index++) {
            if (text.length() > 0) text.append(" | ");
            text.append(reasons.getString(index));
        }
        return text.toString();
    }

    private boolean negativeSatisfied() throws JSONException {
        if (!negativeMode || negativeBlock == null) return false;
        if (unmatched.length() != 1) return false;
        JSONObject entry = unmatched.getJSONObject(0);
        String selector = negativeBlock.optString("selector", "");
        String owner = negativeBlock.optString("expectedOwner", "");
        String terminal = negativeBlock.optString("expectedTerminal", "");
        int status = negativeBlock.optInt("expectedStatus", -1);
        return selector.equals(entry.optString("selector"))
            && owner.equals(entry.isNull("owner") ? "" : entry.optString("owner"))
            && terminal.equals(entry.optString("terminal"))
            && entry.optInt("status", -1) == status
            && entry.isNull("declaredResponse");
    }

    private JSONObject rowById(String id) throws JSONException {
        synchronized (observations) {
            for (int index = 0; index < observations.length(); index++) {
                JSONObject row = observations.getJSONObject(index);
                if (id.equals(row.optString("id"))) return row;
            }
        }
        return null;
    }

    private List<JSONObject> rowsByOwner(JSONArray trace, String owner) throws JSONException {
        List<JSONObject> rows = new ArrayList<>();
        for (int index = 0; index < trace.length(); index++) {
            JSONObject row = trace.getJSONObject(index);
            if (owner.equals(row.optString("owner", ""))) rows.add(row);
        }
        return rows;
    }

    private static boolean deepEqual(Object left, Object right) {
        if (left == null || left == JSONObject.NULL) {
            return right == null || right == JSONObject.NULL;
        }
        if (right == null || right == JSONObject.NULL) return false;
        if (left instanceof JSONObject && right instanceof JSONObject) {
            JSONObject a = (JSONObject) left;
            JSONObject b = (JSONObject) right;
            if (a.length() != b.length()) return false;
            Iterator<String> keys = a.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                if (!b.has(key) || !deepEqual(a.opt(key), b.opt(key))) return false;
            }
            return true;
        }
        if (left instanceof JSONArray && right instanceof JSONArray) {
            JSONArray a = (JSONArray) left;
            JSONArray b = (JSONArray) right;
            if (a.length() != b.length()) return false;
            for (int index = 0; index < a.length(); index++) {
                if (!deepEqual(a.opt(index), b.opt(index))) return false;
            }
            return true;
        }
        if (left instanceof Number && right instanceof Number) {
            return ((Number) left).doubleValue() == ((Number) right).doubleValue();
        }
        return left.equals(right);
    }

    private static boolean matchesMultiset(List<String> actual, List<String> expected) {
        if (actual.size() != expected.size()) return false;
        List<String> left = new ArrayList<>(actual);
        List<String> right = new ArrayList<>(expected);
        Collections.sort(left);
        Collections.sort(right);
        return left.equals(right);
    }

    private static JSONArray toArray(List<String> values) {
        JSONArray array = new JSONArray();
        for (String value : values) array.put(value);
        return array;
    }

    // ------------------------------------------------------------- cleanup

    private JSONObject cleanup(boolean succeeded) throws Exception {
        JSONObject cleanup = new JSONObject();
        cleanupOk = false;
        cleanup.put("runSucceededBeforeCleanup", succeeded);
        admissionStoppedReceipt = false;
        cancellationSignalledReceipt = false;
        gatesReleasedReceipt = false;
        replayOkReceipt = false;
        failOkReceipt = false;
        databaseClosedReceipt = false;
        databaseWasOpen = database != null;
        finalDatabaseSnapshotOk = false;
        ownedJobsTerminatedReceipt = false;
        terminalIntegrityOk = false;
        try {
            if (replay != null) {
                replay.stopAdmission();
            }
            admissionStoppedReceipt = true;
        } catch (Throwable error) {
            cleanup.put("admissionStopError", describe(error));
        }
        try {
            cancellationSignalledReceipt = signalOwnedJobs();
        } catch (Throwable error) {
            cleanup.put("jobSignalError", describe(error));
        }
        try {
            if (replay != null) {
                replay.releaseGates();
            }
            gatesReleasedReceipt = true;
        } catch (Throwable error) {
            cleanup.put("gateReleaseError", describe(error));
        }
        try {
            if (replay != null) {
                cleanup.put("replay", replay.closeAndReport());
                replayOkReceipt = replay.cleanupOk();
            } else {
                cleanup.put("replayNote", "the replay listener never started");
                replayOkReceipt = true;
            }
        } catch (Throwable error) {
            cleanup.put("replayError", describe(error));
        }
        try {
            if (failEndpoint != null) {
                cleanup.put("failEndpoint", failEndpoint.closeAndReport());
                failOkReceipt = failEndpoint.cleanupOk();
            } else {
                cleanup.put("failEndpointNote", "the failure endpoint was never bound");
                failOkReceipt = true;
            }
        } catch (Throwable error) {
            cleanup.put("failEndpointError", describe(error));
        }
        // The gates are free; only now await the owned worker/executor.
        try {
            ownedJobsTerminatedReceipt = awaitOwnedJobs();
        } catch (Throwable error) {
            cleanup.put("ownedJobAwaitError", describe(error));
        }
        if (!ownedJobsTerminatedReceipt) {
            cleanup.put("admissionStopped", admissionStoppedReceipt)
                .put("ownedJobsSignalled", cancellationSignalledReceipt)
                .put("ownedJobsTerminated", false)
                .put("gatesReleased", gatesReleasedReceipt)
                .put("replayStarted", replay != null)
                .put("replayOk", replayOkReceipt)
                .put("failEndpointBound", failEndpoint != null)
                .put("failEndpointOk", failOkReceipt)
                .put("databaseWasOpen", databaseWasOpen)
                .put("databaseQueried", false)
                .put("databaseClosed", database == null)
                .put("finalDatabaseSnapshot", database == null)
                .put("rateLimiterCleanup", "skipped: an owned worker/job is unproved")
                .put("preferencesFenced", new JSONArray())
                .put("preferencesRemoved", new JSONArray())
                .put("preservedForController", true);
            if (scratch.isBound()) {
                JSONObject ownership = new JSONObject()
                    .put("ownership", "created-fresh-root")
                    .put("scratchRoot", scratch.root.getAbsolutePath())
                    .put("scratchRootExistedAtStart", scratch.rootExistedAtStart())
                    .put("preferencesPrefix", scratch.preferencesPrefix());
                JSONArray owned = new JSONArray();
                for (String name : scratch.ownedPreferences()) owned.put(name);
                cleanup.put("ownership", ownership)
                    .put("ownerManifest", readOwnerManifest())
                    .put("ownedPreferences", owned)
                    .put("preferenceResidue", preferenceResidue(owned))
                    .put("scratchRetained", scratch.root.exists())
                    .put("scratchRemoved", false);
            } else {
                cleanup.put("ownership", "none: ownership was never established, prior"
                        + " state left intact")
                    .put("scratchRoot", scratch.root.getAbsolutePath())
                    .put("scratchRootExistedAtStart", scratch.rootExistedAtStart())
                    .put("scratchRetained", scratch.root.exists())
                    .put("scratchRemoved", false);
            }
            finalTerminalSnapshot(cleanup);
            cleanup.put("cleanupFailure", "an owned worker/job did not prove completion;"
                    + " the database, limiter records, owned preferences and root were"
                    + " left untouched for controller force-stop cleanup")
                .put("ownedHandlesRetained", new JSONObject()
                    .put("activeCancelJob", activeCancelJob != null)
                    .put("activeCancelWorker", activeCancelWorker != null)
                    .put("followUpJob", followUpJob != null))
                .put("ok", false);
            cleanupOk = false;
            return cleanup;
        }
        if (database == null) {
            finalDatabaseSnapshotOk = true;
            cleanup.put("finalDatabaseSnapshotNote",
                "the database was never opened; there is no native snapshot to read");
        } else {
            try {
                inventory.put("final", dbCounts());
                finalDatabaseSnapshotOk = true;
            } catch (Throwable error) {
                cleanup.put("finalDatabaseSnapshotError", describe(error));
            }
        }
        if (database != null) {
            try {
                call(database, "close");
                databaseClosedReceipt = true;
                database = null;
            } catch (Throwable error) {
                cleanup.put("databaseError", describe(error));
            }
        } else {
            cleanup.put("databaseNote", "the database was never opened");
            databaseClosedReceipt = true;
        }
        cleanup.put("admissionStopped", admissionStoppedReceipt)
            .put("ownedJobsSignalled", cancellationSignalledReceipt)
            .put("ownedJobsTerminated", ownedJobsTerminatedReceipt)
            .put("gatesReleased", gatesReleasedReceipt)
            .put("replayStarted", replay != null)
            .put("replayOk", replayOkReceipt)
            .put("failEndpointBound", failEndpoint != null)
            .put("failEndpointOk", failOkReceipt)
            .put("databaseWasOpen", databaseWasOpen)
            .put("databaseClosed", databaseClosedReceipt)
            .put("finalDatabaseSnapshot", finalDatabaseSnapshotOk);
        rateLimiterCleanup = removeOwnedRateRecords();
        rateLimiterFinal = rateLimiterSnapshot();
        if (!scratch.isBound()) {
            cleanup.put("ownership", "none: ownership was never established, prior state"
                    + " left intact")
                .put("scratchRoot", scratch.root.getAbsolutePath())
                .put("scratchRootExistedAtStart", scratch.rootExistedAtStart())
                .put("scratchRetained", scratch.root.exists())
                .put("scratchRemoved", false)
                .put("preferencesRemoved", new JSONArray());
            return cleanup;
        }
        JSONObject ownership = new JSONObject()
            .put("ownership", "created-fresh-root")
            .put("scratchRoot", scratch.root.getAbsolutePath())
            .put("scratchRootExistedAtStart", scratch.rootExistedAtStart())
            .put("preferencesPrefix", scratch.preferencesPrefix());
        JSONArray owned = new JSONArray();
        for (String name : scratch.ownedPreferences()) owned.put(name);
        cleanup.put("ownership", ownership)
            .put("ownerManifest", readOwnerManifest())
            .put("ownedPreferences", owned)
            .put("preferenceResidue", preferenceResidue(owned));
        boolean terminalOk = finalTerminalSnapshot(cleanup);
        boolean resourcesCertain = admissionStoppedReceipt
            && cancellationSignalledReceipt && ownedJobsTerminatedReceipt
            && gatesReleasedReceipt && replayOkReceipt && failOkReceipt
            && databaseClosedReceipt && finalDatabaseSnapshotOk;
        if (!resourcesCertain) {
            cleanup.put("preservedForController", true)
                .put("scratchRetained", scratch.root.exists())
                .put("scratchRemoved", false)
                .put("preferencesRemoved", new JSONArray())
                .put("cleanupFailure", "the run did not prove every owned resource"
                    + " terminated; the owned root and preferences are preserved for"
                    + " controller force-stop cleanup")
                .put("uncertainReceipts", new JSONObject()
                    .put("admissionStopped", admissionStoppedReceipt)
                    .put("ownedJobsSignalled", cancellationSignalledReceipt)
                    .put("ownedJobsTerminated", ownedJobsTerminatedReceipt)
                    .put("gatesReleased", gatesReleasedReceipt)
                    .put("replayOk", replayOkReceipt)
                    .put("failEndpointOk", failOkReceipt)
                    .put("databaseClosed", databaseClosedReceipt)
                    .put("finalDatabaseSnapshot", finalDatabaseSnapshotOk)
                    .put("terminalIntegrity", terminalOk))
                .put("ok", false);
            cleanupOk = false;
            return cleanup;
        }
        JSONArray fenced = new JSONArray();
        boolean allFenced = true;
        for (String name : scratch.ownedPreferences()) {
            boolean fencedOk = scratch.fence(name);
            allFenced &= fencedOk;
            fenced.put(new JSONObject().put("name", name).put("ok", fencedOk));
        }
        JSONArray removed = new JSONArray();
        boolean allRemoved = true;
        for (String name : scratch.ownedPreferences()) {
            boolean removedOk = scratch.deletePreference(name);
            allRemoved &= removedOk;
            removed.put(new JSONObject().put("name", name).put("ok", removedOk));
        }
        boolean rootRemoved = scratch.removeRoot();
        cleanup.put("preferencesFenced", fenced)
            .put("preferencesRemoved", removed)
            .put("scratchRetained", !rootRemoved && scratch.root.exists())
            .put("scratchRemoved", rootRemoved)
            .put("rootExistsAfterRemoval", scratch.root.exists())
            .put("preservedForController", false);
        cleanupOk = resourcesCertain && terminalOk && allFenced && allRemoved
            && rootRemoved && rateLimiterCleanup.optBoolean("resolved", false);
        if (!cleanupOk) {
            cleanup.put("cleanupFailure", "resourcesCertain=" + resourcesCertain
                + " terminalOk=" + terminalOk
                + " everyPreferenceFenced=" + allFenced
                + " everyPreferenceRemoved=" + allRemoved
                + " rootRemoved=" + rootRemoved
                + " rateMapResolved=" + rateLimiterCleanup.optBoolean("resolved", false));
        }
        cleanup.put("ok", cleanupOk);
        return cleanup;
    }

    /**
     * The final authoritative snapshot after admission stopped, the gates were freed,
     * the listeners/workers/executor stopped and the database closed. Requests, owners,
     * terminals, observation shape, server errors and the owned resources are all
     * required; the one intended negative omission is accounted for explicitly.
     */
    private boolean finalTerminalSnapshot(JSONObject cleanup) {
        JSONObject terminal = new JSONObject();
        if (!corpusIndexed) {
            try {
                terminal.put("requests", requests.length())
                    .put("unmatched", unmatched.length())
                    .put("serverErrors", serverErrors.length())
                    .put("requestMatch", false)
                    .put("observationMatch", false)
                    .put("notEvaluated", true)
                    .put("status", "not-evaluated")
                    .put("reason", "setup did not complete before the request/"
                        + "observation indexes were built")
                    .put("ok", false);
                cleanup.put("terminal", terminal);
            } catch (JSONException ignored) {
                // The failure is already visible through cleanupOk and the run failure.
            }
            terminalIntegrityOk = false;
            return false;
        }
        try {
            requestCheckValue = requestCheck();
            observationCheckValue = observationCheck();
            boolean requestsOk = requestCheckValue.optBoolean("match", false);
            boolean observationsOk = observationCheckValue.optBoolean("match", false);
            boolean resourcesOk = admissionStoppedReceipt && cancellationSignalledReceipt
                && ownedJobsTerminatedReceipt && gatesReleasedReceipt && replayOkReceipt
                && failOkReceipt && databaseClosedReceipt && finalDatabaseSnapshotOk
                && (replay == null || (replay.listenersClosedReceipt()
                    && replay.workersStoppedReceipt() && replay.executorTerminatedReceipt()
                    && replay.openAfterCloseReceipt() == 0));
            JSONObject resources = new JSONObject()
                .put("admissionStopped", admissionStoppedReceipt)
                .put("ownedJobsSignalled", cancellationSignalledReceipt)
                .put("ownedJobsTerminated", ownedJobsTerminatedReceipt)
                .put("gatesReleased", gatesReleasedReceipt)
                .put("replayStarted", replay != null)
                .put("replayOk", replayOkReceipt)
                .put("listenersClosed", replay == null || replay.listenersClosedReceipt())
                .put("workersStopped", replay == null || replay.workersStoppedReceipt())
                .put("executorTerminated", replay == null
                    || replay.executorTerminatedReceipt())
                .put("openConnectionsAfterClose", replay == null
                    ? 0 : replay.openAfterCloseReceipt())
                .put("failEndpointBound", failEndpoint != null)
                .put("failEndpointOk", failOkReceipt)
                .put("databaseWasOpen", databaseWasOpen)
                .put("databaseClosed", databaseClosedReceipt)
                .put("finalDatabaseSnapshot", finalDatabaseSnapshotOk);
            boolean errorsEmpty = serverErrors.length() == 0;
            boolean integrity = requestsOk && observationsOk && errorsEmpty && resourcesOk;
            terminal.put("requests", requests.length())
                .put("unmatched", unmatched.length())
                .put("serverErrors", serverErrors.length())
                .put("requestMatch", requestsOk)
                .put("observationMatch", observationsOk)
                .put("intendedOmission", requestCheckValue.optBoolean("intendedOmission",
                    false))
                .put("otherUnmatched", requestCheckValue.optInt("otherUnmatched", 0))
                .put("negativeMode", negativeMode)
                .put("resources", resources)
                .put("integrityOk", integrity)
                .put("ok", integrity);
            cleanup.put("terminal", terminal);
            terminalIntegrityOk = integrity;
            return integrity;
        } catch (Throwable error) {
            terminalIntegrityOk = false;
            try {
                requestCheckValue = new JSONObject().put("match", false)
                    .put("error", describe(error));
                observationCheckValue = new JSONObject().put("match", false)
                    .put("error", describe(error));
                terminal.put("ok", false).put("integrityOk", false)
                    .put("error", describe(error));
                cleanup.put("terminal", terminal);
            } catch (JSONException ignored) {
                // The failure is already visible through cleanupOk and the run failure.
            }
            return false;
        }
    }

    /**
     * Signals and awaits every owned job/worker. A live worker or active job keeps its
     * handle and makes the receipt false; the caller must not delete owned residue.
     */
    private boolean cancelLeftoverJob() {
        boolean signalled = signalOwnedJobs();
        boolean terminated = awaitOwnedJobs();
        return signalled && terminated;
    }

    private JSONObject readOwnerManifest() {
        JSONObject manifest = new JSONObject();
        File file = new File(scratch.root, OWNER_FILE);
        try {
            if (!file.isFile()) {
                return manifest.put("exists", false);
            }
            byte[] bytes = readFile(file);
            return new JSONObject(new String(bytes, StandardCharsets.UTF_8))
                .put("exists", true)
                .put("sha256", sha256(bytes));
        } catch (Throwable error) {
            try {
                return manifest.put("exists", file.exists()).put("error", describe(error));
            } catch (JSONException ignored) {
                return new JSONObject();
            }
        }
    }

    private JSONArray preferenceResidue(JSONArray owned) throws Exception {
        JSONArray residue = new JSONArray();
        File directory = new File(getTargetContext().getApplicationInfo().dataDir,
            "shared_prefs");
        for (int index = 0; index < owned.length(); index++) {
            String name = owned.getString(index);
            File xml = new File(directory, name + ".xml");
            File bak = new File(directory, name + ".xml.bak");
            residue.put(new JSONObject()
                .put("name", name)
                .put("xml", xml.getAbsolutePath())
                .put("xmlExists", xml.exists())
                .put("xmlLength", xml.length())
                .put("bakExists", bak.exists()));
        }
        return residue;
    }

    private JSONArray queryRows(String sql) throws Exception {
        Object helper = call(database, "getOpenHelper");
        Object readable = call(helper, "getReadableDatabase");
        Object cursor = call(readable, "query", sql);
        JSONArray rows = new JSONArray();
        try {
            String[] columns = (String[]) call(cursor, "getColumnNames");
            while ((Boolean) call(cursor, "moveToNext")) {
                JSONObject row = new JSONObject();
                for (int index = 0; index < columns.length; index++) {
                    Object cell = call(cursor, "getString", Integer.valueOf(index));
                    row.put(columns[index], cell == null ? JSONObject.NULL : cell);
                }
                rows.put(row);
            }
        } finally {
            call(cursor, "close");
        }
        return rows;
    }

    // --------------------------------------------------------- reflection

    private Object runSuspend(ClassLoader loader, SuspendCall call) throws Throwable {
        Object context = loader.loadClass("kotlin.coroutines.EmptyCoroutineContext")
            .getField("INSTANCE").get(null);
        return runBlockingWithContext(context, call);
    }

    private static Object callSuspend(Class<?> owner, Object instance, String name,
            int parameterCount, Object[] arguments, Object continuation) throws Throwable {
        Method target = null;
        for (Method candidate : owner.getMethods()) {
            if (!candidate.getName().equals(name)
                    && !candidate.getName().startsWith(name + "-")) {
                continue;
            }
            if (candidate.getParameterCount() != parameterCount) continue;
            if (!candidate.getParameterTypes()[parameterCount - 1].getName()
                    .equals("kotlin.coroutines.Continuation")) {
                continue;
            }
            target = candidate;
        }
        if (target == null) {
            throw new IllegalStateException("frozen suspend entry absent: " + name);
        }
        Object[] full = new Object[parameterCount];
        System.arraycopy(arguments, 0, full, 0, arguments.length);
        full[parameterCount - 1] = continuation;
        try {
            return target.invoke(instance, full);
        } catch (InvocationTargetException error) {
            throw error.getCause();
        }
    }

    private static List<?> unwrapResult(Object result) throws Exception {
        if (result instanceof List) return (List<?>) result;
        if (result == null) throw new IllegalStateException("the stage returned null");
        Object payload = null;
        for (Method candidate : result.getClass().getDeclaredMethods()) {
            if (candidate.getName().startsWith("unbox-impl")
                    && Modifier.isStatic(candidate.getModifiers())
                    && candidate.getParameterCount() == 1) {
                candidate.setAccessible(true);
                payload = candidate.invoke(null, result);
            }
        }
        if (payload == null) {
            for (Field field : result.getClass().getDeclaredFields()) {
                if (!field.getName().equals("value")) continue;
                field.setAccessible(true);
                payload = field.get(result);
            }
        }
        if (payload instanceof List) return (List<?>) payload;
        if (payload != null && payload.getClass().getName().contains("Failure")) {
            for (Field field : payload.getClass().getDeclaredFields()) {
                if (!field.getName().equals("exception")) continue;
                field.setAccessible(true);
                Object exception = field.get(payload);
                if (exception instanceof Exception) throw (Exception) exception;
                if (exception instanceof Throwable) {
                    throw new IllegalStateException((Throwable) exception);
                }
            }
        }
        throw new IllegalStateException("the stage result is "
            + result.getClass().getName() + " payload=" + payload);
    }

    private static Object call(Object target, String name, Object... args) throws Exception {
        for (Method method : target.getClass().getMethods()) {
            if (!method.getName().equals(name) || method.getParameterTypes().length != args.length) {
                continue;
            }
            Class<?>[] types = method.getParameterTypes();
            boolean matches = true;
            for (int index = 0; index < types.length; index++) {
                if (!accepts(types[index], args[index])) {
                    matches = false;
                    break;
                }
            }
            if (!matches) continue;
            try {
                return method.invoke(target, args);
            } catch (InvocationTargetException error) {
                throw asException(error.getCause());
            }
        }
        throw new IllegalStateException("no method " + name + " with " + args.length
            + " arguments on " + target.getClass().getName());
    }

    private static boolean accepts(Class<?> type, Object value) {
        if (value == null) return !type.isPrimitive();
        if (type.isPrimitive()) {
            if (type == boolean.class) return value instanceof Boolean;
            if (type == int.class) return value instanceof Integer;
            if (type == long.class) return value instanceof Long;
            if (type == double.class) return value instanceof Double;
            if (type == float.class) return value instanceof Float;
            if (type == short.class) return value instanceof Short;
            if (type == byte.class) return value instanceof Byte;
            if (type == char.class) return value instanceof Character;
            return false;
        }
        return type.isInstance(value);
    }

    private static Exception asException(Throwable error) {
        if (error instanceof Exception) return (Exception) error;
        return new IllegalStateException(error);
    }

    private static String str(Class<?> type, Object target, String getter) throws Exception {
        Object value = type.getMethod(getter).invoke(target);
        return value == null ? "" : value.toString();
    }

    // ------------------------------------------------------- report helpers

    private String timeoutReport(String where) {
        JSONObject report = new JSONObject();
        try {
            report.put("fixtureId", corpus == null ? "" : corpus.optString("fixtureId", ""))
                .put("corpusVersion", corpus == null
                    ? JSONObject.NULL : Integer.valueOf(corpus.optInt("corpusVersion", -1)))
                .put("baselineCommit", corpus == null
                    ? "" : corpus.optString("baselineCommit", ""))
                .put("entryPoint", corpus == null ? "" : corpus.optString("entryPoint", ""))
                .put("platform", "android")
                .put("fingerprint", Build.FINGERPRINT)
                .put("recordedAt", timestamp())
                .put("runId", runId == null ? "" : runId)
                .put("pid", android.os.Process.myPid())
                .put("status", "incomplete")
                .put("promotable", false)
                .put("terminalIntegrityOk", false)
                .put("timedOut", true)
                .put("timeoutStage", where)
                .put("requests", snapshot(requests))
                .put("stageTrace", snapshot(stageTrace))
                .put("unmatchedRequests", snapshot(unmatched))
                .put("serverErrors", snapshot(serverErrors))
                .put("observations", snapshot(observations))
                .put("analysisFailure", "timeout: no result after " + WATCHDOG_MILLIS
                    + "ms in stage " + where);
        } catch (Throwable error) {
            try {
                report.put("analysisFailure", "timeout in stage " + where
                    + "; report assembly: " + describe(error));
            } catch (JSONException ignored) {
                // The human line on the stream still names the stage.
            }
        }
        return report.toString();
    }

    private static JSONArray snapshot(JSONArray source) {
        synchronized (source) {
            try {
                return new JSONArray(source.toString());
            } catch (JSONException error) {
                return new JSONArray();
            }
        }
    }

    private static JSONArray jsonMap(Map<?, ?> map) throws JSONException {
        JSONArray pairs = new JSONArray();
        if (map == null) return pairs;
        List<String> keys = new ArrayList<>();
        for (Object key : map.keySet()) keys.add(String.valueOf(key));
        Collections.sort(keys);
        for (String key : keys) {
            Object value = null;
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (String.valueOf(entry.getKey()).equals(key)) {
                    value = entry.getValue();
                    break;
                }
            }
            pairs.put(new JSONArray().put(key)
                .put(value == null ? JSONObject.NULL : String.valueOf(value)));
        }
        return pairs;
    }

    private static Object nullToNull(Object value) {
        return value == null ? JSONObject.NULL : value;
    }

    private byte[] readAsset(String name) throws IOException {
        try (InputStream input = getContext().getAssets().open(name)) {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int read;
            while ((read = input.read(chunk)) > 0) buffer.write(chunk, 0, read);
            return buffer.toByteArray();
        }
    }

    private static byte[] readFile(File file) throws IOException {
        try (InputStream input = new FileInputStream(file)) {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int read;
            while ((read = input.read(chunk)) > 0) buffer.write(chunk, 0, read);
            return buffer.toByteArray();
        }
    }

    private static byte[] lf(byte[] bytes) {
        ByteArrayOutputStream out = new ByteArrayOutputStream(bytes.length);
        for (int index = 0; index < bytes.length; index++) {
            if (bytes[index] == '\r' && index + 1 < bytes.length && bytes[index + 1] == '\n') {
                continue;
            }
            out.write(bytes[index]);
        }
        return out.toByteArray();
    }

    private static String lineEndings(byte[] bytes) {
        int crlf = 0;
        int lf = 0;
        int loneCr = 0;
        for (int index = 0; index < bytes.length; index++) {
            if (bytes[index] == '\r') {
                if (index + 1 < bytes.length && bytes[index + 1] == '\n') {
                    crlf++;
                    index++;
                } else {
                    loneCr++;
                }
            } else if (bytes[index] == '\n') {
                lf++;
            }
        }
        if (crlf > 0 && lf == 0 && loneCr == 0) return "crlf";
        if (crlf == 0 && lf > 0 && loneCr == 0) return "lf";
        if (crlf == 0 && lf == 0 && loneCr == 0) return "none";
        return "mixed";
    }

    private static String base64(String text) {
        return android.util.Base64.encodeToString(text.getBytes(StandardCharsets.UTF_8),
            android.util.Base64.NO_WRAP);
    }

    private static String sha256(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = new FileInputStream(file)) {
            byte[] chunk = new byte[65536];
            int read;
            while ((read = input.read(chunk)) > 0) digest.update(chunk, 0, read);
        }
        return hex(digest.digest());
    }

    private static String sha256(byte[] bytes) throws Exception {
        return hex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder();
        for (byte value : bytes) result.append(String.format("%02x", value & 255));
        return result.toString();
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

    private static JSONObject deriveCancelOutcome(String workerOutcome, boolean aborted,
            boolean terminated, boolean jobDone, int lateCount, boolean valuesUnchanged,
            boolean databaseUnchanged) throws JSONException {
        boolean receipts = aborted && terminated && jobDone && lateCount == 0
            && valuesUnchanged && databaseUnchanged;
        String outcome;
        String category;
        if ("cancelled".equals(workerOutcome) && receipts) {
            outcome = "cancelled";
            category = "cancellation";
        } else if ("failure".equals(workerOutcome)
                || "completed-normally".equals(workerOutcome)) {
            outcome = "failure";
            category = "unknown";
        } else {
            outcome = "incomplete";
            category = "unresolved-entry";
        }
        return new JSONObject().put("outcome", outcome).put("category", category)
            .put("receiptsComplete", receipts);
    }

    private static JSONObject deriveFollowUpFreshness(Object cancelJob, Object followUpJob,
            Object cancelContext, Object followUpContext, Object cancelSource,
            Object followUpSource, String cancelKey, String followUpKey) throws JSONException {
        boolean jobFresh = cancelJob != null && followUpJob != null && cancelJob != followUpJob;
        boolean contextFresh = cancelContext != null && followUpContext != null
            && cancelContext != followUpContext;
        boolean sameSource = cancelSource != null && cancelSource == followUpSource;
        boolean sameKey = cancelKey != null && cancelKey.equals(followUpKey);
        return new JSONObject()
            .put("jobIdentityFresh", jobFresh)
            .put("contextIdentityFresh", contextFresh)
            .put("sameSourceObject", sameSource)
            .put("sameSourceKey", sameKey)
            .put("jobLevel", "created-parent")
            .put("proven", jobFresh && contextFresh && sameSource && sameKey);
    }

    private static boolean isCancellation(Throwable error) {
        for (Throwable current = error; current != null; current = current.getCause()) {
            if (current.getClass().getName().contains("CancellationException")) return true;
        }
        return false;
    }

    private static String categoryOf(Throwable error) {
        for (Throwable current = error; current != null; current = current.getCause()) {
            String name = current.getClass().getName();
            String simple = current.getClass().getSimpleName();
            if (name.contains("CancellationException")) return "cancellation";
            if ("TocEmptyException".equals(simple)) return "empty-required-result";
            if (current instanceof IOException) return "network-failure";
            if (simple.endsWith("ConnectException") || simple.endsWith("SocketException")
                    || simple.endsWith("UnknownHostException")
                    || simple.endsWith("EOFException")
                    || simple.endsWith("SSLException")) {
                return "network-failure";
            }
        }
        return "unknown";
    }

    private interface SuspendCall {
        Object run(Object continuation) throws Throwable;
    }

    private static final class Owner {
        final String step;
        final String family;
        final String cohort;

        Owner(String step, String family, String cohort) {
            this.step = step;
            this.family = family;
            this.cohort = cohort;
        }
    }

    private static final class IncompleteStep extends Exception {
        final String reason;

        IncompleteStep(String reason) {
            super(reason);
            this.reason = reason;
        }
    }

    /** The measured cancellation completed and its receipts passed; the row is not ok. */
    private static final class CancelledExecution extends Exception {
    }

    private static final class StateSnapshot {
        final JSONObject portable = new JSONObject();
        JSONObject db = new JSONObject();
    }

    private static final class CancelMembers {
        final Method newJob;
        final Method plus;
        final Object emptyContext;
        final Method cancel;
        final Method cancelDefault;
        final Method isActive;
        final Method isCompleted;
        final JSONObject report;

        CancelMembers(Method newJob, Method plus, Object emptyContext, Method cancel,
                Method cancelDefault, Method isActive, Method isCompleted,
                JSONObject report) {
            this.newJob = newJob;
            this.plus = plus;
            this.emptyContext = emptyContext;
            this.cancel = cancel;
            this.cancelDefault = cancelDefault;
            this.isActive = isActive;
            this.isCompleted = isCompleted;
            this.report = report;
        }
    }

    // --------------------------------------------------------------- replay

    /**
     * One explicit loopback listener on the corpus origin. A request is matched by
     * method, path and the exact raw query bytes the client sent; the corpus' selector is
     * unique, so every recorded request keeps the causal step it was declared for even
     * when it arrives late. Declared cohort members are held until every member is
     * in flight or the bounded cohort window expires. The one held response is released
     * only on client abort or teardown.
     */
    private static final class BoundaryReplay {
        private final Map<String, Owner> owners;
        private final Map<String, JSONObject> active = new LinkedHashMap<>();
        private final Map<String, CohortState> cohorts = new LinkedHashMap<>();
        private final Map<String, Integer> attempts = new LinkedHashMap<>();
        private final Map<String, Boolean> lastHadResponse = new LinkedHashMap<>();
        private final JSONArray requests;
        private final JSONArray unmatched;
        private final JSONArray serverErrors;
        private final JSONArray stageTrace;
        private final AtomicReference<String> stage;
        private final List<Listener> listeners = new ArrayList<>();
        private final ExecutorService clients = Executors.newFixedThreadPool(8);
        private final Set<Socket> openSockets = new LinkedHashSet<>();
        private final AtomicInteger open = new AtomicInteger();
        private final AtomicInteger sendCounter = new AtomicInteger();
        private final AtomicBoolean stopping = new AtomicBoolean();
        private final JSONArray listenerCloseErrors = new JSONArray();
        private final int threadCount;
        private final HoldState holdState = new HoldState();
        private volatile boolean listenersClosed;
        private volatile boolean workersStopped;
        private volatile boolean executorTerminated;
        private volatile int openBeforeClose;
        private volatile int openAfterClose = -1;

        BoundaryReplay(JSONObject corpus, Map<String, Owner> owners, JSONArray requests,
                JSONArray unmatched, JSONArray serverErrors, JSONArray stageTrace,
                AtomicReference<String> stage, String dropId, int threadCount, String origin)
                throws Exception {
            this.owners = owners;
            this.requests = requests;
            this.unmatched = unmatched;
            this.serverErrors = serverErrors;
            this.stageTrace = stageTrace;
            this.stage = stage;
            this.threadCount = threadCount;
            URI uri = URI.create(origin);
            if (uri.getHost() == null || uri.getPort() < 1) {
                throw new IllegalStateException("the replay origin is not host:port");
            }
            listeners.add(new Listener(uri.getHost(), uri.getPort()));
            JSONArray responses = corpus.getJSONArray("responses");
            int holds = 0;
            for (int index = 0; index < responses.length(); index++) {
                JSONObject response = responses.getJSONObject(index);
                String id = response.getString("id");
                if (id.equals(dropId)) continue;
                String selector = selectorOf(response);
                if (active.containsKey(selector)) {
                    throw new IllegalStateException("two active responses select " + selector);
                }
                active.put(selector, response);
                if (response.optBoolean("hold", false)) {
                    holds++;
                    holdState.selector = selector;
                    holdState.timeoutMs = response.optLong("holdTimeoutMs", 20000);
                }
            }
            if (holds > 1) throw new IllegalStateException("the corpus declares two held"
                + " responses");
            JSONArray declaredCohorts = corpus.getJSONArray("cohorts");
            for (int index = 0; index < declaredCohorts.length(); index++) {
                JSONObject cohort = declaredCohorts.getJSONObject(index);
                cohorts.put(cohort.getString("id"), new CohortState(cohort.getString("id"),
                    cohort.getInt("size"), cohort.getInt("timeoutMs")));
            }
        }

        String endpoints() {
            StringBuilder text = new StringBuilder();
            for (Listener listener : listeners) {
                if (text.length() > 0) text.append(", ");
                text.append(listener.host).append(':').append(listener.port);
            }
            return text.toString();
        }

        void start() throws Exception {
            try {
                for (Listener listener : listeners) {
                    ServerSocket server = new ServerSocket();
                    listener.server = server;
                    listener.created = true;
                    server.setReuseAddress(true);
                    server.bind(new InetSocketAddress(InetAddress.getByName(listener.host),
                        listener.port), 32);
                }
            } catch (Throwable error) {
                for (Listener listener : listeners) closeListener(listener);
                throw new IllegalStateException("replay listener bind failed: "
                    + describe(error), error);
            }
            for (Listener listener : listeners) {
                listener.worker = new Thread(() -> accept(listener),
                    "http-boundary-replay-" + listener.host);
                listener.worker.setDaemon(true);
                listener.worker.start();
            }
        }

        void stopAdmission() {
            stopping.set(true);
        }

        void releaseHold() {
            holdState.requestRelease();
        }

        void releaseGates() {
            holdState.requestRelease();
            synchronized (cohorts) {
                for (CohortState state : cohorts.values()) {
                    synchronized (state) {
                        if (!state.released) state.release("teardown");
                    }
                }
            }
        }

        boolean allCohortsEntered() {
            for (CohortState state : cohorts.values()) {
                synchronized (state) {
                    if (state.arrived.isEmpty()) return false;
                }
            }
            return true;
        }

        JSONObject batchReport(String cohortId) throws JSONException {
            CohortState state = cohorts.get(cohortId);
            if (state == null) {
                return new JSONObject().put("cohort", cohortId)
                    .put("error", "the corpus declares no such cohort");
            }
            synchronized (state) {
                JSONArray membership = new JSONArray();
                List<String> sorted = new ArrayList<>(state.arrived);
                Collections.sort(sorted);
                for (String selector : sorted) membership.put(selector);
                return new JSONObject()
                    .put("cohort", cohortId)
                    .put("cohortSize", state.size)
                    .put("cohortTimeoutMs", state.timeoutMs)
                    .put("entered", !state.arrived.isEmpty())
                    .put("cohortComplete", state.complete)
                    .put("releaseReason", state.releaseReason == null
                        ? JSONObject.NULL : state.releaseReason)
                    .put("inFlightPeak", state.peak)
                    .put("membership", membership)
                    .put("threadCount", threadCount);
            }
        }

        /**
         * Provenance for a cohort: the gate's planned release decision is kept apart from
         * the response flushes the server actually completed. Client completion order is
         * unobserved here and is never inferred from the gate loop.
         */
        JSONObject batchEvidence(String cohortId) throws JSONException {
            CohortState state = cohorts.get(cohortId);
            if (state == null) {
                return new JSONObject().put("cohort", cohortId)
                    .put("error", "the corpus declares no such cohort");
            }
            synchronized (state) {
                JSONArray planned = new JSONArray();
                List<String> plannedOrder = new ArrayList<>(state.plannedReleaseOrder.keySet());
                Collections.sort(plannedOrder, (left, right) -> Integer.compare(
                    state.plannedReleaseOrder.get(left).intValue(),
                    state.plannedReleaseOrder.get(right).intValue()));
                for (String selector : plannedOrder) {
                    planned.put(new JSONObject().put("selector", selector)
                        .put("sequence", state.plannedReleaseOrder.get(selector)));
                }
                JSONArray arrival = new JSONArray();
                for (String selector : state.arrived) arrival.put(selector);
                List<JSONObject> sentRequests = new ArrayList<>();
                synchronized (requests) {
                    for (int index = 0; index < requests.length(); index++) {
                        JSONObject request = requests.getJSONObject(index);
                        if (!cohortId.equals(request.optString("cohort", ""))) continue;
                        if (request.optInt("sendSequence", -1) > 0) sentRequests.add(request);
                    }
                }
                sentRequests.sort((left, right) -> Integer.compare(
                    left.optInt("sendSequence", -1), right.optInt("sendSequence", -1)));
                JSONArray sent = new JSONArray();
                for (JSONObject request : sentRequests) {
                    sent.put(new JSONObject()
                        .put("selector", request.optString("selector"))
                        .put("sendSequence", request.optInt("sendSequence", -1)));
                }
                return new JSONObject()
                    .put("cohort", cohortId)
                    .put("plannedReleaseOrder", planned)
                    .put("plannedLabel", "gate release decision, assigned before any send")
                    .put("actualSendOrder", sent)
                    .put("actualLabel", "server response flush completion")
                    .put("arrivalOrder", arrival)
                    .put("clientCompletionUnobserved", true);
            }
        }

        boolean listenersClosedReceipt() {
            return listenersClosed;
        }

        boolean workersStoppedReceipt() {
            return workersStopped;
        }

        boolean executorTerminatedReceipt() {
            return executorTerminated;
        }

        int openAfterCloseReceipt() {
            return openAfterClose;
        }

        JSONObject closeAndReport() throws Exception {
            openBeforeClose = open.get();
            stopping.set(true);
            boolean listenersOk = true;
            for (Listener listener : listeners) listenersOk &= closeListener(listener);
            listenersClosed = listenersOk;
            boolean workers = true;
            for (Listener listener : listeners) {
                if (listener.worker == null) continue;
                listener.worker.join(2000);
                if (listener.worker.isAlive()) workers = false;
            }
            synchronized (openSockets) {
                for (Socket socket : new ArrayList<>(openSockets)) closeQuietly(socket);
                openSockets.clear();
            }
            clients.shutdownNow();
            executorTerminated = clients.awaitTermination(3, TimeUnit.SECONDS);
            long deadline = System.currentTimeMillis() + CLOSE_WAIT_MILLIS;
            while (open.get() != 0 && System.currentTimeMillis() < deadline) {
                Thread.sleep(20);
            }
            openAfterClose = open.get();
            workersStopped = workers;
            JSONArray closeErrors = snapshot(listenerCloseErrors);
            JSONArray failures = new JSONArray();
            for (int index = 0; index < closeErrors.length(); index++) {
                failures.put(closeErrors.get(index));
            }
            if (!listenersClosed) failures.put("one or more replay listeners are still open");
            if (openAfterClose != 0) failures.put("connections still open: " + openAfterClose);
            if (!workersStopped) failures.put("replay workers did not stop");
            if (!executorTerminated) failures.put("replay client executor did not terminate");
            if (serverErrors.length() != 0) {
                failures.put("server errors during the run: " + serverErrors.length());
            }
            return new JSONObject()
                .put("openConnectionsBeforeClose", openBeforeClose)
                .put("openConnectionsAfterClose", openAfterClose)
                .put("listenersClosed", listenersClosed)
                .put("listenerClosure", listenerClosure())
                .put("listenerCloseErrors", closeErrors)
                .put("workersStopped", workersStopped)
                .put("executorTerminated", executorTerminated)
                .put("serverErrors", snapshot(serverErrors))
                .put("failures", failures)
                .put("ok", failures.length() == 0);
        }

        boolean cleanupOk() {
            return listenersClosed && listenerCloseErrors.length() == 0
                && serverErrors.length() == 0 && workersStopped && executorTerminated
                && openAfterClose == 0;
        }

        private boolean closeListener(Listener listener) {
            ServerSocket server = listener.server;
            if (server == null) {
                listener.closed = true;
                return true;
            }
            try {
                server.close();
            } catch (IOException error) {
                synchronized (listenerCloseErrors) {
                    listenerCloseErrors.put(listener.host + ":" + listener.port
                        + " close failed: " + error);
                }
            }
            boolean closed = server.isClosed();
            if (!closed) {
                synchronized (listenerCloseErrors) {
                    listenerCloseErrors.put(listener.host + ":" + listener.port
                        + " is still open after close");
                }
            }
            listener.closed = closed;
            return closed;
        }

        private JSONArray listenerClosure() throws JSONException {
            JSONArray closure = new JSONArray();
            for (Listener listener : listeners) {
                closure.put(new JSONObject()
                    .put("host", listener.host)
                    .put("port", listener.port)
                    .put("created", listener.created)
                    .put("closed", listener.closed));
            }
            return closure;
        }

        private void accept(Listener listener) {
            while (!stopping.get() && listener.server != null && !listener.server.isClosed()) {
                try {
                    Socket client = listener.server.accept();
                    open.incrementAndGet();
                    synchronized (openSockets) {
                        openSockets.add(client);
                    }
                    clients.submit(() -> {
                        try (Socket socket = client) {
                            serve(socket, listener);
                        } catch (Exception error) {
                            if (!stopping.get()) {
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
                    if (!stopping.get() && listener.server != null
                            && !listener.server.isClosed()) {
                        synchronized (serverErrors) {
                            serverErrors.put(error.toString());
                        }
                    }
                }
            }
        }

        private void serve(Socket socket, Listener listener) throws Exception {
            socket.setSoTimeout(20000);
            socket.setTcpNoDelay(true);
            InputStream input = socket.getInputStream();
            OutputStream output = socket.getOutputStream();
            while (true) {
                String requestLine;
                try {
                    requestLine = readLine(input);
                } catch (SocketTimeoutException idle) {
                    return;
                }
                if (requestLine == null || requestLine.isEmpty()) return;
                JSONArray headerLines = new JSONArray();
                Map<String, String> headers = new LinkedHashMap<>();
                String line;
                while ((line = readLine(input)) != null && !line.isEmpty()) {
                    headerLines.put(line);
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
                byte[] bodyBytes = new byte[Math.max(0, length)];
                int read = 0;
                while (read < bodyBytes.length) {
                    int count = input.read(bodyBytes, read, bodyBytes.length - read);
                    if (count < 0) break;
                    read += count;
                }
                String body = new String(bodyBytes, 0, read, StandardCharsets.UTF_8);
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
                String selector = method + " " + path + "?" + rawQuery;
                Owner owner = owners.get(selector);
                JSONObject declared = active.get(selector);
                int prior;
                synchronized (attempts) {
                    prior = attempts.containsKey(selector) ? attempts.get(selector) : 0;
                    attempts.put(selector, Integer.valueOf(prior + 1));
                }
                boolean previousResponse;
                synchronized (lastHadResponse) {
                    previousResponse = Boolean.TRUE.equals(lastHadResponse.get(selector));
                }
                String attemptKind = prior == 0 ? "initial" : (previousResponse
                    ? "source-status-retry" : "transport-reconnect");
                JSONObject observed = new JSONObject()
                    .put("listener", listener.host)
                    .put("owner", owner == null ? JSONObject.NULL : owner.step)
                    .put("family", owner == null ? JSONObject.NULL : owner.family)
                    .put("cohort", owner == null || owner.cohort == null
                        ? JSONObject.NULL : owner.cohort)
                    .put("attempt", prior + 1)
                    .put("attemptKind", attemptKind)
                    .put("selector", selector)
                    .put("method", method)
                    .put("target", target)
                    .put("path", path)
                    .put("rawQuery", rawQuery)
                    .put("query", new JSONObject(decodeQuery(rawQuery)))
                    .put("headers", new JSONObject(headers))
                    .put("headerLines", headerLines)
                    .put("body", body)
                    .put("bodyLength", read)
                    .put("bodySha256", sha256(bodyBytes.length == read
                        ? bodyBytes : Arrays.copyOf(bodyBytes, read)))
                    .put("receivedAtNanos", System.nanoTime())
                    .put("respondedAtNanos", -1L)
                    .put("sentAtNanos", -1L)
                    .put("sendSequence", -1)
                    .put("status", -1)
                    .put("terminal", "received")
                    .put("declaredResponse", declared == null
                        ? JSONObject.NULL : declared.optString("id"))
                    .put("outcome", "received")
                    .put("stage", stage.get());
                synchronized (requests) {
                    observed.put("index", requests.length() + 1);
                    requests.put(observed);
                    synchronized (stageTrace) {
                        stageTrace.put(new JSONObject()
                            .put("stage", stage.get())
                            .put("listener", listener.host)
                            .put("target", target)
                            .put("owner", owner == null ? JSONObject.NULL : owner.step));
                    }
                }
                if (stopping.get()) {
                    respondStatus(output, observed, 503, "Service Unavailable",
                        "replay admission is stopped", "rejected-after-shutdown");
                    return;
                }
                if (declared == null) {
                    synchronized (unmatched) {
                        unmatched.put(observed);
                    }
                    respondStatus(output, observed, 404, "Not Found",
                        "undeclared replay request", "omitted-unmatched");
                    return;
                }
                if (declared.optBoolean("hold", false)) {
                    hold(socket, input, observed);
                    return;
                }
                if (owner != null && owner.cohort != null) {
                    cohortGate(cohorts.get(owner.cohort), selector, observed);
                }
                respond(output, observed);
            }
        }

        private void hold(Socket socket, InputStream input, JSONObject request)
                throws Exception {
            update(request, "outcome", "held");
            holdState.enter(request.optString("selector"));
            socket.setSoTimeout(100);
            long deadline = System.currentTimeMillis() + holdState.timeoutMs;
            boolean aborted = false;
            long failureAtNanos = -1;
            while (System.currentTimeMillis() < deadline) {
                if (holdState.releaseRequested.get()) break;
                try {
                    int value = input.read();
                    if (value == -1) {
                        aborted = true;
                        failureAtNanos = System.nanoTime();
                        break;
                    }
                } catch (SocketTimeoutException timeoutError) {
                    continue;
                } catch (SocketException closed) {
                    aborted = true;
                    failureAtNanos = System.nanoTime();
                    break;
                } catch (IOException failure) {
                    aborted = true;
                    failureAtNanos = System.nanoTime();
                    break;
                }
            }
            if (aborted) {
                boolean teardownCaused = holdState.releaseRequested.get()
                    && holdState.releasedAtOrBefore(failureAtNanos);
                if (teardownCaused) {
                    update(request, "terminal", "hold-released-at-teardown");
                    update(request, "outcome", "hold-released-at-teardown");
                } else {
                    holdState.abort();
                    update(request, "terminal", "client-aborted");
                    update(request, "outcome", "client-aborted");
                }
            } else if (holdState.releaseRequested.get()) {
                update(request, "terminal", "hold-released-at-teardown");
                update(request, "outcome", "hold-released-at-teardown");
            } else {
                holdState.expire();
                update(request, "terminal", "hold-window-expired");
                update(request, "outcome", "hold-window-expired");
            }
        }

        private void cohortGate(CohortState state, String selector, JSONObject request)
                throws Exception {
            if (state == null) return;
            synchronized (state) {
                state.arrived.add(selector);
                state.inFlight++;
                if (state.inFlight > state.peak) state.peak = state.inFlight;
                if (state.windowStartNanos < 0) state.windowStartNanos = System.nanoTime();
                if (state.arrived.size() >= state.size && !state.released) {
                    state.release("complete");
                }
                while (!state.released) {
                    long elapsed = TimeUnit.NANOSECONDS.toMillis(
                        System.nanoTime() - state.windowStartNanos);
                    long remaining = state.timeoutMs - elapsed;
                    if (remaining <= 0) {
                        state.release("cohort-window");
                        break;
                    }
                    state.wait(Math.min(remaining, 100));
                }
                update(request, "cohortComplete", Boolean.valueOf(state.complete));
                update(request, "releaseReason", state.releaseReason == null
                    ? JSONObject.NULL : state.releaseReason);
            }
        }

        private void respond(OutputStream output, JSONObject request) throws Exception {
            JSONObject declared = active.get(request.optString("selector"));
            byte[] bytes = declared.optString("body", "").getBytes(StandardCharsets.UTF_8);
            int status = declared.optInt("status", 200);
            StringBuilder head = new StringBuilder();
            head.append("HTTP/1.1 ").append(status).append(' ').append(reason(status))
                .append("\r\n");
            JSONObject headers = declared.optJSONObject("headers");
            if (headers != null) {
                Iterator<String> names = headers.keys();
                while (names.hasNext()) {
                    String name = names.next();
                    head.append(name).append(": ").append(headers.optString(name))
                        .append("\r\n");
                }
            }
            head.append("Content-Length: ").append(bytes.length)
                .append("\r\nConnection: keep-alive\r\n\r\n");
            output.write(head.toString().getBytes(StandardCharsets.US_ASCII));
            output.write(bytes);
            output.flush();
            long sentAt = System.nanoTime();
            int sendSequence = sendCounter.incrementAndGet();
            update(request, "respondedAtNanos", Long.valueOf(sentAt));
            update(request, "sentAtNanos", Long.valueOf(sentAt));
            update(request, "sendSequence", Integer.valueOf(sendSequence));
            update(request, "status", Integer.valueOf(status));
            update(request, "terminal", "responded");
            update(request, "outcome", "responded");
            synchronized (lastHadResponse) {
                lastHadResponse.put(request.optString("selector"), Boolean.TRUE);
            }
            exitCohort(request.optString("selector"));
        }

        private void respondStatus(OutputStream output, JSONObject request, int status,
                String reason, String text, String terminal) throws Exception {
            byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
            String head = "HTTP/1.1 " + status + " " + reason + "\r\n"
                + "Content-Type: text/plain\r\nContent-Length: " + bytes.length + "\r\n"
                + "Connection: keep-alive\r\n\r\n";
            output.write(head.getBytes(StandardCharsets.US_ASCII));
            output.write(bytes);
            output.flush();
            long sentAt = System.nanoTime();
            int sendSequence = sendCounter.incrementAndGet();
            update(request, "respondedAtNanos", Long.valueOf(sentAt));
            update(request, "sentAtNanos", Long.valueOf(sentAt));
            update(request, "sendSequence", Integer.valueOf(sendSequence));
            update(request, "status", Integer.valueOf(status));
            update(request, "terminal", terminal);
            update(request, "outcome", terminal);
            synchronized (lastHadResponse) {
                lastHadResponse.put(request.optString("selector"), Boolean.TRUE);
            }
        }

        private void exitCohort(String selector) throws JSONException {
            Owner owner = owners.get(selector);
            if (owner == null || owner.cohort == null) return;
            CohortState state = cohorts.get(owner.cohort);
            if (state == null) return;
            synchronized (state) {
                state.exit();
            }
        }

        private void update(JSONObject request, String key, Object value) throws JSONException {
            synchronized (requests) {
                request.put(key, value);
            }
        }

        private static void closeQuietly(Socket socket) {
            if (socket == null) return;
            try {
                socket.close();
            } catch (IOException ignored) {
                // Already closed.
            }
        }

        private static final class Listener {
            final String host;
            final int port;
            ServerSocket server;
            Thread worker;
            boolean created;
            boolean closed;

            Listener(String host, int port) {
                this.host = host;
                this.port = port;
            }
        }
    }

    private static final class CohortState {
        final String id;
        final int size;
        final long timeoutMs;
        final LinkedHashSet<String> arrived = new LinkedHashSet<>();
        final Map<String, Integer> plannedReleaseOrder = new LinkedHashMap<>();
        int inFlight;
        int peak;
        boolean released;
        boolean complete;
        String releaseReason;
        long windowStartNanos = -1;
        long releasedAtNanos = -1;

        CohortState(String id, int size, long timeoutMs) {
            this.id = id;
            this.size = size;
            this.timeoutMs = timeoutMs;
        }

        void release(String reason) {
            this.released = true;
            this.releaseReason = reason;
            if ("complete".equals(reason)) this.complete = true;
            this.releasedAtNanos = System.nanoTime();
            List<String> members = new ArrayList<>(arrived);
            int sequence = members.size();
            for (String member : members) {
                plannedReleaseOrder.put(member, Integer.valueOf(sequence--));
            }
            notifyAll();
        }

        void exit() {
            if (inFlight > 0) inFlight--;
        }
    }

    private static final class HoldState {
        final CountDownLatch entered = new CountDownLatch(1);
        final CountDownLatch abortObserved = new CountDownLatch(1);
        final AtomicBoolean aborted = new AtomicBoolean();
        final AtomicBoolean expired = new AtomicBoolean();
        final AtomicBoolean releaseRequested = new AtomicBoolean();
        final java.util.concurrent.atomic.AtomicLong releaseRequestedAtNanos =
            new java.util.concurrent.atomic.AtomicLong(0);
        volatile String selector;
        volatile long timeoutMs = 20000;
        volatile long enteredAtNanos;
        volatile long abortedAtNanos;

        void enter(String selector) {
            this.selector = selector;
            this.enteredAtNanos = System.nanoTime();
            entered.countDown();
        }

        void requestRelease() {
            releaseRequestedAtNanos.compareAndSet(0, System.nanoTime());
            releaseRequested.set(true);
        }

        boolean releasedAtOrBefore(long nanos) {
            long releasedAt = releaseRequestedAtNanos.get();
            return releasedAt > 0 && releasedAt <= nanos;
        }

        void abort() {
            aborted.set(true);
            abortedAtNanos = System.nanoTime();
            abortObserved.countDown();
        }

        void expire() {
            expired.set(true);
            abortObserved.countDown();
        }

        boolean awaitEntered(long timeout, TimeUnit unit) throws InterruptedException {
            return entered.await(timeout, unit);
        }

        /**
         * Waits for abort or expiry, but returns true only for an actual client abort.
         * An expiry or a teardown-only release is never accepted as an abort.
         */
        boolean awaitAbort(long timeout, TimeUnit unit) throws InterruptedException {
            abortObserved.await(timeout, unit);
            return aborted.get();
        }
    }

    // -------------------------------------------------------- fail endpoint

    private static final class FailEndpoint {
        private final JSONObject spec;
        private final AtomicBoolean armed = new AtomicBoolean();
        private final AtomicBoolean closed = new AtomicBoolean();
        private final JSONArray connections = new JSONArray();
        private final JSONArray errors = new JSONArray();
        private final Set<Socket> openSockets = new LinkedHashSet<>();
        private ServerSocket server;
        private Thread worker;
        private int assignedPort;
        private long boundAtNanos;
        private long armedAtNanos;
        private volatile boolean workerStopped;

        FailEndpoint(JSONObject spec) {
            this.spec = spec;
        }

        void bind() throws Exception {
            ServerSocket socket = new ServerSocket();
            server = socket;
            socket.setReuseAddress(true);
            socket.bind(new InetSocketAddress(
                InetAddress.getByName(spec.getString("host")), spec.optInt("port", 0)), 8);
            assignedPort = socket.getLocalPort();
            boundAtNanos = System.nanoTime();
        }

        void arm() {
            if (!armed.compareAndSet(false, true)) return;
            armedAtNanos = System.nanoTime();
            worker = new Thread(this::accept, "http-boundary-fail-endpoint");
            worker.setDaemon(true);
            worker.start();
        }

        int accepted() {
            synchronized (connections) {
                return connections.length();
            }
        }

        private void accept() {
            while (!closed.get()) {
                Socket client = null;
                try {
                    client = server.accept();
                    synchronized (openSockets) {
                        openSockets.add(client);
                    }
                    try (Socket socket = client) {
                        JSONObject connection = readConnection(socket);
                        synchronized (connections) {
                            connection.put("index", connections.length() + 1);
                            connection.put("classification", connections.length() == 0
                                ? "initial" : "transport-reconnect");
                            connections.put(connection);
                        }
                    } catch (Throwable error) {
                        synchronized (errors) {
                            errors.put(error.toString());
                        }
                    } finally {
                        synchronized (openSockets) {
                            openSockets.remove(client);
                        }
                    }
                } catch (IOException error) {
                    if (!closed.get()) {
                        synchronized (errors) {
                            errors.put(error.toString());
                        }
                    }
                }
            }
        }

        private JSONObject readConnection(Socket socket) throws Exception {
            JSONObject connection = new JSONObject()
                .put("acceptedAtNanos", Long.valueOf(System.nanoTime()));
            socket.setSoTimeout(2000);
            InputStream input = socket.getInputStream();
            String requestLine;
            try {
                requestLine = readLine(input);
            } catch (SocketTimeoutException idle) {
                requestLine = null;
            }
            if (requestLine == null) {
                return connection.put("requestObserved", false)
                    .put("expected", false)
                    .put("terminal", "accepted-and-closed-without-request")
                    .put("closedAtNanos", Long.valueOf(System.nanoTime()));
            }
            Map<String, String> headers = new LinkedHashMap<>();
            String line;
            while ((line = readLine(input)) != null && !line.isEmpty()) {
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
            byte[] bodyBytes = new byte[Math.max(0, length)];
            int read = 0;
            while (read < bodyBytes.length) {
                int count = input.read(bodyBytes, read, bodyBytes.length - read);
                if (count < 0) break;
                read += count;
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
            boolean expected = "GET".equals(method) && "/f/search".equals(path)
                && "keyword=fail&page=1".equals(rawQuery);
            return connection.put("requestObserved", true)
                .put("requestLine", requestLine)
                .put("method", method)
                .put("target", target)
                .put("path", path)
                .put("rawQuery", rawQuery)
                .put("headers", new JSONObject(headers))
                .put("bodyLength", read)
                .put("expected", expected)
                .put("terminal", "accepted-and-closed-without-response")
                .put("closedAtNanos", Long.valueOf(System.nanoTime()));
        }

        boolean expectedOnly() throws JSONException {
            synchronized (connections) {
                for (int index = 0; index < connections.length(); index++) {
                    if (!connections.getJSONObject(index).optBoolean("expected", false)) {
                        return false;
                    }
                }
            }
            return armed.get();
        }

        JSONObject report() {
            JSONObject report = new JSONObject();
            try {
                JSONArray snapshotConnections = new JSONArray();
                synchronized (connections) {
                    for (int index = 0; index < connections.length(); index++) {
                        snapshotConnections.put(connections.getJSONObject(index));
                    }
                }
                JSONArray snapshotErrors = new JSONArray();
                synchronized (errors) {
                    for (int index = 0; index < errors.length(); index++) {
                        snapshotErrors.put(errors.get(index));
                    }
                }
                report.put("host", spec.getString("host"))
                    .put("requestedPort", spec.optInt("port", 0))
                    .put("assignedPort", assignedPort)
                    .put("boundAtNanos", boundAtNanos)
                    .put("armed", armed.get())
                    .put("armedAtNanos", armedAtNanos)
                    .put("acceptedConnections", snapshotConnections.length())
                    .put("transportReconnects", Math.max(0,
                        snapshotConnections.length() - 1))
                    .put("connections", snapshotConnections)
                    .put("errors", snapshotErrors)
                    .put("closed", closed.get())
                    .put("workerStopped", workerStopped)
                    .put("classification", spec.optJSONObject("classification"));
            } catch (JSONException error) {
                try {
                    report.put("reportError", describe(error));
                } catch (JSONException ignored) {
                    // The report still carries the failure text.
                }
            }
            return report;
        }

        JSONObject closeAndReport() throws JSONException {
            closed.set(true);
            try {
                if (server != null) server.close();
            } catch (IOException error) {
                synchronized (errors) {
                    errors.put("listener close failed: " + error);
                }
            }
            if (worker != null) {
                try {
                    worker.join(2000);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
                workerStopped = !worker.isAlive();
            } else {
                workerStopped = true;
            }
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
            JSONObject report = report();
            try {
                report.put("workerStopped", workerStopped)
                    .put("ok", cleanupOk());
            } catch (JSONException ignored) {
                // The boolean is already in the report.
            }
            return report;
        }

        boolean cleanupOk() throws JSONException {
            boolean serverClosed = server == null || server.isClosed();
            synchronized (errors) {
                return closed.get() && serverClosed && workerStopped && errors.length() == 0
                    && expectedOnly();
            }
        }
    }

    // ------------------------------------------------------------- utilities

    private static String reason(int status) {
        switch (status) {
            case 200:
                return "OK";
            case 404:
                return "Not Found";
            case 502:
                return "Bad Gateway";
            case 503:
                return "Service Unavailable";
            default:
                return "Status";
        }
    }

    private static String readLine(InputStream input) throws IOException {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        int value;
        while ((value = input.read()) != -1) {
            if (value == '\n') break;
            if (value != '\r') buffer.write(value);
        }
        if (value == -1 && buffer.size() == 0) return null;
        return new String(buffer.toByteArray(), StandardCharsets.ISO_8859_1);
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
                query.put(URLDecoder.decode(name, "UTF-8"),
                    URLDecoder.decode(value, "UTF-8"));
            } catch (Exception error) {
                query.put(name, value);
            }
        }
        return query;
    }
}
