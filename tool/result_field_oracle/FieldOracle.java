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
import java.util.concurrent.Callable;
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
    /** The reference save event tag (EventBus.kt:32). */
    private static final String SAVE_CONTENT_TAG = "saveContent";
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
        final Throwable[] primaryHolder = new Throwable[1];
        try {
            runWithCleanup(this::runBody, this::outerCleanup);
        } catch (Throwable error) {
            primaryHolder[0] = error;
        }
        try {
            final Throwable primaryFailure = primaryHolder[0];
            if (primaryFailure != null) {
                // The actual final reporting: log, persist, then serialize the
                // updated chain at the status boundary.
                String chain = reportFailure(primaryFailure,
                    persistStep(primaryFailure), reportStep(primaryFailure));
                if (scratch != null && !scratch.isBound()) scratch.refuseWaiters(chain);
                status.putString("stream", "Fields oracle harness error: " + chain + "\n");
                finished.set(true);
                finish(1, status);
                return;
            }
            int recorded = newFamily ? caseRecords.length() : cases.length();
            status.putString("stream", "Fields oracle recorded " + requests.length()
                + " requests and " + recorded + " cases"
                + (caseFailures.length() == 0 ? "" : ", " + caseFailures.length() + " failed")
                + "\n");
            finished.set(true);
            finish(caseFailures.length() == 0 ? -1 : 1, status);
        } catch (Throwable error) {
            // The real fallback: keep the original primary, attach this finish
            // failure and the fallback reporting/persistence failures, and
            // update the status and durable reporting with the complete chain
            // before the best-effort second finish.
            final Throwable finishError = error;
            final Throwable root = primaryHolder[0] != null ? primaryHolder[0] : finishError;
            String chain = reportFinishFailure(finishError, primaryHolder[0],
                persistStep(root), reportStep(root));
            if (scratch != null && !scratch.isBound()) scratch.refuseWaiters(chain);
            status.putString("stream", "Fields oracle harness error: " + chain + "\n");
            finished.set(true);
            finish(1, status);
        }
    }

    /** The persistence step of the final reporting, as a callable. */
    private Callable<JSONObject> persistStep(Throwable target) {
        return () -> {
            Throwable persistenceError = persistFailureReport(target);
            if (persistenceError != null) {
                throw persistenceError instanceof Exception
                    ? (Exception) persistenceError
                    : new IllegalStateException(persistenceError);
            }
            return new JSONObject().put("persisted", true);
        };
    }

    /** The logger step of the final reporting, as a callable. */
    private Callable<JSONObject> reportStep(Throwable target) {
        return () -> {
            Throwable logError = safeLog("harness error: " + describeChain(target));
            if (logError != null) {
                throw logError instanceof Exception
                    ? (Exception) logError
                    : new IllegalStateException(logError);
            }
            return new JSONObject().put("logged", true);
        };
    }

    /**
     * The actual fallback finish-failure reporting.
     *
     * <p>[primary] stays the root when it exists and receives [finishError] as
     * suppressed; without a primary the finish failure is the root. The
     * reporting and persistence steps then run, each failure attached the same
     * way, and the returned chain is the one the final status carries.
     */
    static String reportFinishFailure(Throwable finishError, Throwable primary,
            Callable<JSONObject> persist, Callable<JSONObject> report) {
        Throwable root = primary != null ? primary : finishError;
        if (primary != null && finishError != null && finishError != primary) {
            primary.addSuppressed(finishError);
        }
        // The same report -> persist -> serialize sequence the normal failure
        // path runs; only the root selection differs.
        return reportFailure(root, persist, report);
    }

    /**
     * The actual final failure reporting: report, persist, then serialize the
     * updated chain.
     *
     * <p>Both reporting steps are attempted even when one fails, each failure is
     * attached to the original as suppressed, and the returned chain is the one
     * the status boundary carries. This is the sequence the harness failure path
     * runs; the host controls drive the same method with supplied steps.
     */
    static String reportFailure(Throwable failure, Callable<JSONObject> persist,
            Callable<JSONObject> report) {
        Throwable reportError = null;
        if (report != null) {
            try {
                report.call();
            } catch (Throwable error) {
                reportError = error;
            }
        }
        if (reportError != null) failure.addSuppressed(reportError);
        Throwable persistenceError = null;
        if (persist != null) {
            try {
                persist.call();
            } catch (Throwable error) {
                persistenceError = error;
            }
        }
        if (persistenceError != null) failure.addSuppressed(persistenceError);
        return describeChain(failure);
    }

    /**
     * A log call that can never interrupt a cleanup or reporting path, and that
     * retains its own failure so the caller can serialize it.
     */
    private Throwable safeLog(String message) {
        try {
            log(message);
            return null;
        } catch (Throwable error) {
            // A logger failure must not skip later owned cleanup or reporting.
            return error;
        }
    }

    /**
     * F4: persist the actual failure.
     *
     * <p>When a full report already exists it is preserved and its
     * {@code analysisFailure} is set to the complete chain. Only a run whose
     * normal report was never initialized writes the minimal failure-only JSON,
     * and only into the already-bound owned scratch. A persistence error is
     * returned so the caller can attach it to the original failure.
     */
    private Throwable persistFailureReport(Throwable failure) {
        return persistFailureReport(scratch != null && scratch.isBound(), output,
            scratch == null ? null : scratch.root, report, caseFailures, corpus, failure);
    }

    /**
     * The actual failure-persistence choice and write.
     *
     * <p>This is the one algorithm the collector's failure path runs: a bound
     * owned scratch preserves an initialized full report and sets its
     * {@code analysisFailure}; a bound run whose report was never initialized
     * writes the minimal failure-only JSON to the explicit output or the owned
     * default path; an unbound scratch writes nothing and mutates nothing. The
     * real write error is returned so the caller can attach it.
     */
    static Throwable persistFailureReport(boolean bound, File explicitOutput, File ownedRoot,
            JSONObject report, JSONObject caseFailures, JSONObject corpus, Throwable failure) {
        try {
            if (!bound) return null;
            String chain = describeChain(failure);
            if (report != null) {
                report.put("analysisFailure", chain);
                writeReportFile(explicitOutput, report);
                return null;
            }
            File target = explicitOutput != null ? explicitOutput : new File(ownedRoot, REPORT);
            JSONObject minimal = new JSONObject()
                .put("fixtureId", corpus == null ? "unknown" : corpus.optString("fixtureId", ""))
                .put("failureOnly", true)
                .put("analysisFailure", chain)
                .put("caseFailures", caseFailures)
                .put("recordedAt", timestamp());
            writeReportFile(target, minimal);
            return null;
        } catch (Throwable error) {
            return error;
        }
    }

    /** Writes one report file as UTF-8 JSON; the only report-writing IO. */
    private static void writeReportFile(File target, JSONObject content)
            throws IOException, JSONException {
        try (FileOutputStream stream = new FileOutputStream(target)) {
            stream.write(content.toString(2).getBytes(StandardCharsets.UTF_8));
        }
    }

    /**
     * One lifecycle body with unconditional cleanup.
     *
     * <p>The body runs first; the cleanup then runs on every path, including a
     * body that threw before any report or output existed. The primary failure
     * and the cleanup failure are both retained, the cleanup failure is attached
     * to the primary as suppressed, and the complete chain is serialized through
     * the standard {@code printStackTrace} writer. This is the one algorithm the
     * collector's outer run and its saved case both use.
     */
    static JSONObject runWithCleanup(Callable<JSONObject> body, Callable<JSONObject> close)
            throws Throwable {
        Throwable primary = null;
        JSONObject result = null;
        if (body != null) {
            try {
                result = body.call();
            } catch (Throwable error) {
                primary = error;
            }
        }
        Throwable cleanupFailure = null;
        JSONObject closedProof = null;
        if (close != null) {
            try {
                closedProof = close.call();
            } catch (Throwable error) {
                cleanupFailure = error;
            }
        }
        // A close that ran must prove the domain is actually closed, or state
        // that the caller explicitly accepted a tolerated failure. A bare false
        // or missing proof is a failure, never a success.
        if (cleanupFailure == null && close != null
                && (closedProof == null || (!closedProof.optBoolean("closed", false)
                    && !closedProof.optBoolean("accepted", false)))) {
            cleanupFailure = new IllegalStateException(
                "the cleanup did not prove a closed domain");
        }
        if (primary != null) {
            if (cleanupFailure != null) primary.addSuppressed(cleanupFailure);
            throw primary;
        }
        if (cleanupFailure != null) throw cleanupFailure;
        return result == null ? new JSONObject() : result;
    }

    /** The complete throwable chain, through the standard writer. */
    static String describeChain(Throwable error) {
        if (error == null) return "";
        java.io.StringWriter writer = new java.io.StringWriter();
        error.printStackTrace(new java.io.PrintWriter(writer));
        return writer.toString();
    }

    /** The lifecycle body: everything before the final cleanup. */
    private JSONObject runBody() throws Exception {
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
                if (selectedDatabase == null) {
                    selectedDatabase = loader.loadClass("io.legado.app.data.AppDatabaseKt")
                        .getMethod("getAppDb").invoke(null);
                }
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
                    // The case reporting logger runs BEFORE the chain is
                    // serialized, so its own failure is part of the saved chain.
                    Throwable caseLogError = safeLog("case " + id + " failed: " + describe(error));
                    if (caseLogError != null) error.addSuppressed(caseLogError);
                    String chain = describeChain(error);
                    caseFailures.put(id, chain);
                    if (newFamily && fields02Observation != null) {
                        try {
                            fields02Observation.put("failure", chain)
                                .put("requests", requestSlice(fields02RequestStart));
                            caseRecords.put(fields02Observation);
                        } catch (Throwable ignored) {
                            // The failure is still recorded; do not fabricate a record.
                        }
                    }
                    // F1: for the lifecycle corpus any case failure escapes to the
                    // unconditional outer cleanup; no later case runs in unknown
                    // state. Ordinary corpora keep their existing disposition.
                    if (newFamily && lifecycleCorpus()) {
                        throw error instanceof Exception ? (Exception) error
                            : new IllegalStateException(error);
                    }
                }
                if (newFamily && lifecycleCorpus() && guardCaptureFailed()) {
                    throw new IllegalStateException(
                        "the saved-content guard recorded a capture failure in case " + id);
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
            return new JSONObject().put("recorded", newFamily
                ? caseRecords.length() : cases.length());
        } catch (Throwable error) {
            throw error;
        }
    }

    /** Writes the owner-completion receipt once resource closure is known. */
    interface OwnerWrite {
        JSONObject write(boolean closureProved) throws Exception;
    }

    /**
     * The actual outer cleanup sequence: every owned domain is attempted in
     * order, a failure in one never skips the rest, and the owner receipt is
     * written only after the resource facts are known.
     *
     * <p>This is the one sequence the collector's {@link #outerCleanup()} runs
     * and the host controls drive; the domain actions are supplied by the
     * caller, the sequencing, gating and aggregation are this method's.
     */
    static JSONObject runOuterSequence(
            Callable<JSONObject> report,
            Callable<JSONObject> replay,
            Callable<JSONObject> guard,
            Callable<JSONObject> database,
            Callable<JSONObject> terminal,
            Callable<JSONObject> preferences,
            OwnerWrite owner,
            Callable<JSONObject> finalReport,
            boolean strict,
            boolean selected,
            JSONObject cleanup) throws Exception {
        List<Throwable> failures = new ArrayList<>();
        List<Throwable> fatal = new ArrayList<>();
        List<String> tolerated = new ArrayList<>();
        JSONObject reportState =
            domain(failures, fatal, tolerated, "report", report, strict, selected, cleanup);
        JSONObject replayState =
            domain(failures, fatal, tolerated, "replay", replay, strict, selected, cleanup);
        JSONObject guardState =
            domain(failures, fatal, tolerated, "guard", guard, strict, selected, cleanup);
        JSONObject databaseState =
            domain(failures, fatal, tolerated, "database", database, strict, selected, cleanup);
        JSONObject terminalState =
            domain(failures, fatal, tolerated, "terminal", terminal, strict, selected, cleanup);
        JSONObject preferencesState = domain(failures, fatal, tolerated, "preferences",
            preferences, strict, selected, cleanup);
        // Q4: the final measured activity-launch count is a real failure fact on
        // its own; it does not by itself mean the owned resources stayed open.
        if (selected && terminalState.optInt("activityLaunchAttempts", 0) != 0) {
            IllegalStateException activity = new IllegalStateException(
                "a final activity launch was attempted: "
                    + terminalState.optInt("activityLaunchAttempts", 0));
            failures.add(activity);
            fatal.add(activity);
        }
        // F2: closure is an independent fact about the owned resources, never
        // "no errors anywhere". A report or logger failure does not make the
        // resources unclosed, and an unclosed resource is never a success.
        final boolean closureProved = resourceClosureProved(
            replayState, guardState, databaseState, terminalState, preferencesState);
        JSONObject ownerState = domain(failures, fatal, tolerated, "owner",
            () -> owner == null ? new JSONObject().put("applicable", false)
                : owner.write(closureProved), strict, selected, cleanup);
        // Q3: a lifecycle run additionally requires the applicable owner to have
        // positively completed. Refusal is a failure, not a silent no-op.
        if (strict && ownerState.optBoolean("applicable", true)
                && !ownerState.optBoolean("ownerComplete", false)) {
            IllegalStateException refused = new IllegalStateException(
                "the applicable owner did not complete: " + ownerState);
            failures.add(refused);
            fatal.add(refused);
        }
        domain(failures, fatal, tolerated, "final-report", finalReport, strict, selected,
            cleanup);
        JSONObject receipt = new JSONObject();
        try {
            receipt.put("report", reportState).put("replay", replayState)
                .put("guard", guardState).put("database", databaseState)
                .put("terminal", terminalState).put("preferences", preferencesState)
                .put("owner", ownerState)
                .put("closureProved", closureProved)
                .put("failureCount", failures.size())
                .put("fatalCount", fatal.size())
                .put("toleratedFailures", tolerated.size())
                // The resource facts stay truthful. `accepted` is the caller's
                // own disposition for exactly one situation: a non-selected run
                // whose only tolerated failure is the replay close. Nothing else
                // is accepted without a proved closure.
                .put("accepted", !selected && fatal.isEmpty() && !tolerated.isEmpty()
                    && tolerated.stream().allMatch("replay"::equals))
                .put("closed", closureProved && fatal.isEmpty());
        } catch (Throwable ignored) {
            // The failure lists below are the authoritative facts.
        }
        if (!fatal.isEmpty()) {
            IllegalStateException aggregate = new IllegalStateException(
                "outer cleanup recorded " + fatal.size() + " fatal failure(s)");
            for (Throwable failure : fatal) aggregate.addSuppressed(failure);
            throw aggregate;
        }
        if (!failures.isEmpty()) {
            // Q2: the tolerated legacy disposition is logged, and the resource
            // facts stay truthful.
            logQuietly("outer cleanup recorded tolerated failures: "
                + describeChain(failures.get(0)));
            try {
                receipt.put("toleratedFailures", failures.size());
            } catch (Throwable ignored) {
                // The log above already recorded them.
            }
        }
        if (strict && !closureProved) {
            throw new IllegalStateException(
                "the outer cleanup did not prove resource closure: " + receipt);
        }
        return receipt;
    }

    /**
     * Q2: the exact legacy disposition from the pre-repair collector.
     *
     * <p>For a lifecycle run every domain failure is fatal. For a legacy
     * non-selected run only the replay close was tolerated; a report, scratch
     * finalisation or final-report failure was fatal. For a legacy selected run
     * every domain failure was fatal.
     */
    static boolean domainIsFatal(String name, boolean strict, boolean selected) {
        if (strict) return true;
        if (selected) return true;
        return !"replay".equals(name);
    }

    /** Runs one domain, recording its failure as tolerated or fatal. */
    static JSONObject domain(List<Throwable> failures, List<Throwable> fatal,
            List<String> tolerated, String name, Callable<JSONObject> work, boolean strict,
            boolean selected, JSONObject cleanup) {
        List<Throwable> domainFailures = new ArrayList<>();
        List<Throwable> infrastructure = new ArrayList<>();
        JSONObject state = attempt(domainFailures, infrastructure, name, work, cleanup);
        boolean isFatal = domainIsFatal(name, strict, selected);
        for (Throwable failure : domainFailures) {
            failures.add(failure);
            if (isFatal) {
                fatal.add(failure);
            } else {
                tolerated.add(name);
            }
        }
        // A reporting or receipt failure around a domain is never tolerated.
        for (Throwable failure : infrastructure) {
            failures.add(failure);
            fatal.add(failure);
        }
        return state;
    }

    /** Whether each owned resource domain actually reported closure. */
    static boolean resourceClosureProved(JSONObject replay, JSONObject guard,
            JSONObject database, JSONObject terminal, JSONObject preferences) {
        boolean replayClosed = replay.optBoolean("serverClosed", false)
            && replay.optInt("openConnectionsAfterClose", -1) == 0;
        // Q2: a non-selected run's terminal is inapplicable, not unproved; only
        // an applicable terminal must prove itself.
        boolean terminalProved = terminal.optBoolean("applicable", true)
            ? terminal.optBoolean("proved", false) : true;
        return replayClosed
            && applicableClosed(guard)
            && applicableClosed(database)
            && applicableClosed(preferences)
            && terminalProved;
    }

    /** A domain that reported itself inapplicable does not block closure. */
    private static boolean applicableClosed(JSONObject state) {
        return state.optBoolean("applicable", true) ? state.optBoolean("closed", false) : true;
    }

    /**
     * The unconditional outer cleanup: the report, the replay sockets, the
     * process guard, the real database, the terminal proof, the owned preference
     * fences, the owner receipt and the final report, each attempted even when
     * another fails.
     */
    private JSONObject outerCleanup() throws Exception {
        return runOuterSequence(
            () -> {
                writeReport();
                log("report written; failures=" + caseFailures.length());
                return new JSONObject().put("closed", true).put("written", true);
            },
            () -> {
                if (replay == null) return new JSONObject().put("serverClosed", false);
                cleanup.put("openConnections", replay.openConnections());
                replay.close();
                cleanup.put("serverClosed", true);
                int after = replay.openConnections();
                // F5: the existing selected report field the unchanged consumer
                // reads must stay in the persisted cleanup domain.
                cleanup.put("openConnectionsAfterClose", after);
                return new JSONObject().put("serverClosed", true)
                    .put("openConnectionsAfterClose", after);
            },
            () -> {
                if (!newFamily || !lifecycleCorpus()) {
                    return new JSONObject().put("applicable", false);
                }
                JSONObject released = releaseSavedContentGuard();
                cleanup.put("savedContentGuard", released);
                return new JSONObject().put("closed", true).put("receipt", released);
            },
            () -> {
                if (!selectedReference || selectedDatabase == null) {
                    return new JSONObject().put("applicable", false);
                }
                selectedDatabase.getClass().getMethod("close").invoke(selectedDatabase);
                cleanup.put("databaseClosed", true);
                cleanup.put("activityLaunchAttempts", selectedLaunchAttempts());
                return new JSONObject().put("closed", true)
                    .put("activityLaunchAttempts", selectedLaunchAttempts());
            },
            () -> {
                if (!selectedReference) return new JSONObject().put("applicable", false);
                if (!terminalProved) {
                    return new JSONObject().put("closed", false).put("proved", false)
                        .put("reason", "the selected terminal was not proved");
                }
                // Q4: the final measured activity-launch count is reported as a
                // fact; the sequence decides it is fatal without pretending the
                // owned resources stayed open.
                int launches = selectedLaunchAttempts();
                cleanup.put("activityLaunchAttempts", launches);
                return new JSONObject().put("closed", true).put("proved", true)
                    .put("activityLaunchAttempts", launches);
            },
            () -> {
                if (!newFamily) return new JSONObject().put("applicable", false);
                return fenceOwnedPreferences();
            },
            closureProved -> {
                if (!newFamily) return new JSONObject().put("applicable", false);
                return writeOwnerCompletion(closureProved);
            },
            () -> {
                writeReport();
                log("report rewritten with cleanup=" + cleanup);
                return new JSONObject().put("closed", true).put("written", true);
            },
            newFamily && lifecycleCorpus(),
            selectedReference,
            cleanup);
    }

    /**
     * Runs one cleanup domain, recording its failure instead of aborting the
     * rest. A logger failure is retained in the same list and never skips a
     * later domain.
     */
    static JSONObject attempt(List<Throwable> failures, List<Throwable> infrastructure,
            String name, Callable<JSONObject> work, JSONObject cleanupDomain) {
        try {
            return work.call();
        } catch (Throwable error) {
            failures.add(error);
            if (cleanupDomain != null) {
                try {
                    cleanupDomain.put(name + "Failure", describeChain(error));
                } catch (Throwable receiptError) {
                    infrastructure.add(receiptError);
                }
            }
            try {
                Log.i("FieldOracle", "cleanup domain " + name + " failed: " + describe(error));
            } catch (Throwable logError) {
                // A reporting failure around a tolerated domain error is never
                // itself tolerated.
                infrastructure.add(logError);
            }
            try {
                return new JSONObject().put("closed", false).put("failed", true);
            } catch (Throwable ignored) {
                return new JSONObject();
            }
        }
    }

    /** A log call that cannot interrupt a reporting path. */
    static void logQuietly(String message) {
        try {
            Log.i("FieldOracle", message);
        } catch (Throwable ignored) {
            // Reporting must not interrupt the caller.
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
        // The application and storage ownership proof runs here, before the first
        // search can initialise BookHelp (BookList formats the book name through
        // it), so this is the real pre-initialisation boundary rather than a late
        // check inside a later case.
        JSONObject earlyContainment = earlyContainment(identity);
        Class<?> appCtx = getTargetContext().getClassLoader()
            .loadClass("splitties.init.AppCtxKt");
        Object app = appCtx.getMethod("getAppCtx").invoke(null);
        boolean filesRouted = ((android.content.Context) app).getFilesDir()
            .equals(scratch.getFilesDir());
        boolean databaseRouted = ((android.content.Context) app).getDatabasePath("legado.db")
            .equals(scratch.getDatabasePath("legado.db"));
        boolean deviceProtected = ((android.content.Context) app).isDeviceProtectedStorage();
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
            .put("preferenceProbe", probe)
            .put("earlyContainment", earlyContainment);
    }

    /** Whether a canonical path lies inside the owned scratch root. */
    private static boolean within(String path, String root) {
        return path.equals(root) || path.startsWith(root + File.separator);
    }

    /** Whether this corpus declares the saved-content lifecycle observation. */
    private boolean lifecycleCorpus() {
        return corpus != null && corpus.optJSONObject("titleLifecycle") != null;
    }

    /**
     * Actual application and storage ownership, proven by object identity and
     * canonical paths before any reference class can capture the write root.
     *
     * <p>{@code splitties.appCtx} and the ActivityThread application that
     * {@code AppUtils.getApp()} would return must be the same object, that
     * object must be this guard, and its external-files/fallback and database
     * directories must be the bound scratch directories. The guard is enabled
     * before {@code AppUtils.getApp()} is called once, so its lifecycle-callback
     * registration is tracked rather than unguarded.
     */
    private JSONObject earlyContainment(JSONObject identity) throws Exception {
        ClassLoader loader = getTargetContext().getClassLoader();
        Object appCtxValue = loader.loadClass("splitties.init.AppCtxKt")
            .getMethod("getAppCtx").invoke(null);
        Object thread = Class.forName("android.app.ActivityThread")
            .getMethod("currentActivityThread").invoke(null);
        Object threadApp = thread.getClass().getMethod("getApplication").invoke(thread);
        android.content.Context app = (android.content.Context) appCtxValue;
        boolean sameObject = appCtxValue == threadApp;
        boolean guarded = !selectedReference || "io.liber.oracle.nested.GuardedReaderApplication"
            .equals(appCtxValue.getClass().getName());
        // The application object must have been attached to THIS bound scratch,
        // not merely resolve equal canonical paths. This is measured before the
        // guard is armed and before any reference initialiser can create a
        // directory.
        android.content.Context baseContext =
            appCtxValue instanceof android.content.ContextWrapper
                ? ((android.content.ContextWrapper) appCtxValue).getBaseContext() : null;
        boolean baseContextBound = baseContext == scratch;
        File external = app.getExternalFilesDir(null);
        File externalOrFiles = external != null ? external : app.getFilesDir();
        String canonicalExternal = externalOrFiles.getCanonicalPath();
        String canonicalFiles = app.getFilesDir().getCanonicalPath();
        String canonicalDatabase = app.getDatabasePath("legado.db").getCanonicalPath();
        String root = scratch.root.getCanonicalPath();
        boolean externalRouted = within(canonicalExternal, root)
            && canonicalExternal.equals(scratch.getExternalFilesDir(null).getCanonicalPath());
        boolean filesRouted = canonicalFiles.equals(scratch.getFilesDir().getCanonicalPath());
        boolean databaseRouted = canonicalDatabase
            .equals(scratch.getDatabasePath("legado.db").getCanonicalPath());
        JSONObject containment = new JSONObject()
            .put("appCtxClass", appCtxValue.getClass().getName())
            .put("activityThreadAppClass", threadApp == null
                ? JSONObject.NULL : threadApp.getClass().getName())
            .put("sameApplicationObject", sameObject)
            .put("guardedApplication", guarded)
            .put("baseContextBound", baseContextBound)
            .put("baseContextClass", baseContext == null
                ? JSONObject.NULL : baseContext.getClass().getName())
            .put("externalFilesPath", canonicalExternal)
            .put("filesPath", canonicalFiles)
            .put("databasePath", canonicalDatabase)
            .put("scratchRoot", root)
            .put("externalFilesRouted", externalRouted)
            .put("filesRouted", filesRouted)
            .put("databaseRouted", databaseRouted);
        if (!sameObject || !guarded || !baseContextBound || !externalRouted || !filesRouted
                || !databaseRouted) {
            throw new IllegalStateException(
                "the target application or its storage is not this bound scratch: " + containment);
        }
        if (lifecycleCorpus()) {
            Class<?> bridge = Class.forName("io.liber.oracle.nested.SelectedFieldHostBridge");
            bridge.getMethod("arm", android.app.Application.class, ClassLoader.class)
                .invoke(null, appCtxValue, loader);
            // Called once, with the guard already active, so the lifecycle
            // registration it performs is tracked and removable.
            Object appUtilsApp = loader.loadClass("com.jeremyliao.liveeventbus.utils.AppUtils")
                .getMethod("getApp").invoke(null);
            containment.put("appUtilsApplicationClass", appUtilsApp == null
                    ? JSONObject.NULL : appUtilsApp.getClass().getName())
                .put("appUtilsSameApplication", appUtilsApp == appCtxValue);
            if (appUtilsApp != appCtxValue) {
                throw new IllegalStateException(
                    "AppUtils resolves a different application: " + containment);
            }
            // Only now, after ownership is proven, is BookHelp allowed to
            // initialise and capture its write root.
            Class<?> bookHelp = loader.loadClass("io.legado.app.help.book.BookHelp");
            String cachePath = (String) bookHelp.getMethod("getCachePath")
                .invoke(bookHelp.getField("INSTANCE").get(null));
            String canonicalCache = new File(cachePath).getCanonicalPath();
            containment.put("bookHelpCachePath", canonicalCache)
                .put("bookHelpCacheWithinScratch", within(canonicalCache, root));
            if (!within(canonicalCache, root)) {
                throw new IllegalStateException(
                    "the BookHelp write root escapes the owned scratch: " + containment);
            }
            // The database is acquired here, where it is first needed, so the
            // Room path is checked on a real open handle rather than a null field.
            if (selectedDatabase == null) {
                selectedDatabase = loader.loadClass("io.legado.app.data.AppDatabaseKt")
                    .getMethod("getAppDb").invoke(null);
            }
            Object dao = selectedDatabase.getClass().getMethod("getOpenHelper")
                .invoke(selectedDatabase);
            Object database = dao.getClass().getMethod("getWritableDatabase").invoke(dao);
            String roomPath = new File((String) database.getClass().getMethod("getPath")
                .invoke(database)).getCanonicalPath();
            containment.put("roomDatabasePath", roomPath)
                .put("roomDatabaseWithinScratch", within(roomPath, root));
            if (!within(roomPath, root)) {
                throw new IllegalStateException(
                    "the Room database escapes the owned scratch: " + containment);
            }
        }
        return containment;
    }

    /** FIELDS-02 hands the owned scratch/report to the external capture driver. */
    /**
     * Fences every owned preference name, each inside its own boundary, and
     * records the real fence facts. A throwing or false fence is a failure.
     */
    private JSONObject fenceOwnedPreferences() throws Exception {
        if (scratch == null) return new JSONObject().put("applicable", false);
        return fenceOwnedPreferences(scratch, scratch.ownedPreferences(), scratch::fence,
            cleanup, output == null ? null : output.getAbsolutePath());
    }

    /** One owned preference fence attempt; the production caller passes scratch::fence. */
    interface Fence {
        boolean fence(String name);
    }

    /**
     * The actual per-owned-name fence loop.
     *
     * <p>Every owned name is attempted in snapshot order; a false or a thrown
     * fence never skips a later name. The thrown instances are retained in the
     * aggregate, and the recorded cleanup facts stay truthful.
     */
    static JSONObject fenceOwnedPreferences(StateSessionOracle.ScratchContext scratch,
            java.util.Set<String> ownedNames, Fence fence, JSONObject cleanup, String reportPath)
            throws Exception {
        if (scratch == null) return new JSONObject().put("applicable", false);
        JSONArray owned = new JSONArray();
        boolean fenced = true;
        List<Throwable> fenceFailures = new ArrayList<>();
        for (String name : ownedNames) {
            owned.put(name);
            // One throwing fence must not skip the later owned names.
            try {
                fenced &= fence.fence(name);
            } catch (Throwable error) {
                fenced = false;
                fenceFailures.add(error);
            }
        }
        cleanup.put("scratchRoot", scratch.root.getAbsolutePath())
            .put("fixtureId", "FIELDS-02")
            .put("corpusVersion", 1)
            .put("preferencesPrefix", scratch.preferencesPrefix())
            .put("rootExistedAtStart", scratch.rootExistedAtStart())
            .put("ownedPreferences", owned)
            .put("preferencesFenced", fenced)
            .put("reportPath", reportPath == null ? JSONObject.NULL : reportPath)
            .put("rootRetained", scratch.root.exists());
        if (!fenceFailures.isEmpty()) {
            IllegalStateException aggregate = new IllegalStateException(
                "owned preference fences recorded " + fenceFailures.size() + " failure(s)");
            for (Throwable failure : fenceFailures) aggregate.addSuppressed(failure);
            throw aggregate;
        }
        if (!fenced) {
            throw new IllegalStateException("an owned preference fence reported false");
        }
        return new JSONObject().put("closed", true).put("fenced", true);
    }

    /**
     * Writes the owner-completion receipt only when the resource closure was
     * independently proved. A failed body with proved closure may still
     * complete ownership; an unproved closure never does.
     */
    private JSONObject writeOwnerCompletion(boolean closureProved) throws Exception {
        return writeOwnerCompletion(scratch, closureProved, isolation, cleanup);
    }

    /**
     * The actual owner-completion policy and publication.
     *
     * <p>Ownership is published only when the resource closure was independently
     * proved and every isolation fact holds; a refusal records
     * {@code ownerComplete:false} and publishes nothing. Success calls the real
     * {@code scratch.writeOwnerComplete} before the cleanup facts claim it.
     */
    static JSONObject writeOwnerCompletion(StateSessionOracle.ScratchContext scratch,
            boolean closureProved, JSONObject isolation, JSONObject cleanup) throws Exception {
        if (scratch == null) return new JSONObject().put("applicable", false);
        boolean ownershipProven = closureProved && scratch.isBound() && scratch.root.exists()
            && isolation.optBoolean("bound")
            && isolation.optBoolean("filesRouted")
            && isolation.optBoolean("databaseRouted")
            && !isolation.optBoolean("deviceProtected")
            && !isolation.optBoolean("rootExistedAtStart")
            && cleanup.optBoolean("preferencesFenced", false);
        if (!ownershipProven) {
            cleanup.put("ownerComplete", false);
            return new JSONObject().put("closed", false).put("ownerComplete", false);
        }
        String ownerRunId = UUID.randomUUID().toString();
        scratch.writeOwnerComplete(ownerRunId);
        cleanup.put("ownerRunId", ownerRunId).put("ownerComplete", true);
        return new JSONObject().put("closed", true).put("ownerComplete", true);
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
     * The declared saved-name/refresh observation.
     *
     * <p>Setup: the actual parent Book is inserted and read back through the
     * reference BookDao before any child chapter row, because the reference
     * chapter table carries a books foreign key and the selected database
     * enables foreign keys. The two returned chapters then carry distinct raw
     * variable text and are inserted through the reference chapter DAO.
     *
     * <p>Observation: the real {@code getContentAwait(..., needSave=true)}
     * route runs, its save event is observed through the guard's own
     * main-thread observable registration, the stored rows are read back, a
     * real {@code getChapterListAwait} refresh runs, the refreshed list is
     * published through the same DAO insert {@code BookInfoViewModel} uses, and
     * the stored rows are read again. Every row comes from a real object or DAO
     * read.
     *
     * <p>The four phase arrays are the shared cross-platform observation. The
     * containment, setup, preference, event-guard and observer facts are native
     * producer evidence and are recorded separately; the process guard's own
     * closure belongs to the report's cleanup domain, not to a case.
     */
    private void driveTitleLifecycle(JSONObject observed, ClassLoader loader, Object source,
            Object book, List<?> chapters, Class<?> bookClass, Class<?> chapterClass,
            Class<?> webBookClass, Object webBook) throws Exception {
        if (chapters.size() < LIFECYCLE_CHAPTERS) {
            throw new IllegalStateException("title lifecycle needs two TOC chapters");
        }
        JSONObject lifecycle = new JSONObject();
        JSONObject proof = new JSONObject();
        String bookUrl = str(bookClass, book, "getBookUrl");
        String chapterUrl = str(chapterClass, chapters.get(0), "getUrl");

        // R6: the immutable prior preference state is captured BEFORE any
        // mutation and stays reachable by the finally below even when the
        // mutation itself throws.
        JSONObject priorPreference = capturePriorPreference(loader);

        // F9: the actual parent book row, through its own DAO, before any child.
        Object bookDao = selectedDatabase.getClass().getMethod("getBookDao")
            .invoke(selectedDatabase);
        Object bookArray = java.lang.reflect.Array.newInstance(bookClass, 1);
        java.lang.reflect.Array.set(bookArray, 0, book);
        bookDao.getClass().getMethod("insertRows", bookArray.getClass())
            .invoke(bookDao, bookArray);
        Object storedBook = bookDao.getClass().getMethod("getBook", String.class)
            .invoke(bookDao, bookUrl);
        if (storedBook == null
                || !bookUrl.equals(str(bookClass, storedBook, "getBookUrl"))) {
            throw new IllegalStateException("the parent book row was not stored");
        }
        proof.put("bookParent", new JSONObject()
            .put("bookUrl", bookUrl)
            .put("stored", true)
            .put("readBack", true));

        Object dao = selectedDatabase.getClass().getMethod("getBookChapterDao")
            .invoke(selectedDatabase);
        java.lang.reflect.Method setVariable = chapterClass.getMethod("setVariable", String.class);
        for (int index = 0; index < LIFECYCLE_CHAPTERS; index++) {
            setVariable.invoke(chapters.get(index), SEED_VARIABLES[index]);
        }
        lifecycle.put("beforeContent", chapterRows(chapterClass, chapters));
        insertChapters(dao, chapters, chapterClass);
        proof.put("chapterSeed", new JSONObject()
            .put("rows", chapters.size())
            .put("inserted", true));

        // Q5: the actual mutable proof is attached BEFORE the owned lifetime can
        // throw, so a failed case still carries its real partial facts.
        observed.put("titleLifecycleProof", proof);
        observed.put("titleLifecycle", lifecycle);
        // F6: the collector delegates the WHOLE saved-case lifetime to the
        // production seam the host controls also exercise.
        try {
        TocCountWordsLifetime.run(
            defaultPreferences(loader),
            () -> {
                proof.put("saveObserver", saveObservation(loader, "begin", bookUrl, chapterUrl));
                return new JSONObject().put("closed", true);
            },
            () -> {
            stage.set("content");
            log("stage content (saved)");
            int contentRequestStart = requests.length();
            int contentTraceStart = stageTrace.length();
            Object text;
            try {
                text = runSuspend(loader, continuation -> call(webBookClass, webBook,
                    "getContentAwait", 6,
                    new Object[]{source, book, chapters.get(0), null, Boolean.TRUE},
                    continuation));
                if (selectedReference && !(text instanceof String)) {
                    throw new IllegalStateException("selected content result is not a string");
                }
            } catch (Exception error) {
                recordOperationError(observed, "content", contentRequestStart, contentTraceStart,
                    error);
                throw error;
            }
            recordOperation(observed, "content", contentRequestStart, contentTraceStart);
            observed.put("chapter", new JSONObject()
                .put("title", str(chapterClass, chapters.get(0), "getTitle"))
                .put("text", text == null ? "" : text.toString()));

            // F1: the observation's own failure/removal acknowledgement is
            // validated BEFORE the refresh can run.
            JSONObject endReceipt = saveObservation(loader, "end", bookUrl, chapterUrl);
            proof.put("saveEvent", endReceipt);
            JSONObject endProof = adaptObserverClose(endReceipt);
            if (!endProof.optBoolean("closed", false)) {
                throw new IllegalStateException(
                    "the save observation did not close before the refresh: " + endReceipt);
            }
            lifecycle.put("storedAfterContent", storedRows(dao, bookUrl, chapterClass));
            proof.put("contentFiles", contentFiles(loader, bookClass, book));

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
                recordOperationError(observed, "tableOfContents", refreshRequestStart,
                    refreshTraceStart, error);
                throw error;
            }
            recordOperation(observed, "tableOfContents", refreshRequestStart, refreshTraceStart);
            lifecycle.put("refreshedChapters", chapterRows(chapterClass, refreshed));

            // The reference book-information view model publishes a refreshed
            // list with exactly this DAO insert (BookInfoViewModel.kt:527-532).
            insertChapters(dao, refreshed, chapterClass);
            lifecycle.put("storedAfterRefresh", storedRows(dao, bookUrl, chapterClass));
            return lifecycle;
            },
            () -> {
                JSONObject close = saveObservation(loader, "close", bookUrl, chapterUrl);
                proof.put("saveObserverClose", close);
                return adaptObserverClose(close);
            },
            proof);
        } catch (Throwable error) {
            throw error instanceof Exception ? (Exception) error
                : new IllegalStateException(error);
        }
        observed.put("titleLifecycleProof", proof);
        observed.put("titleLifecycle", lifecycle);
    }

    /**
     * Adapts the guard's own observer-close receipt to the lifetime's closed
     * proof. The guard reports removal/event facts, not a generic ``closed``
     * flag, so the collector validates them here rather than equating any
     * receipt with closure.
     */
    static JSONObject adaptObserverClose(JSONObject receipt) throws Exception {
        // The guard acknowledges two actual valid shapes: the first end carries a
        // nested removal acknowledgement, and a second acknowledged end carries
        // the top-level alreadyClosed/removed pair. Both mean the observer is
        // gone; an arbitrary top-level `removed` alone does not.
        JSONObject removal = receipt.optJSONObject("removal");
        boolean nestedRemoved = removal != null && removal.optBoolean("removed", false);
        boolean idempotent = receipt.optBoolean("alreadyClosed", false)
            && receipt.optBoolean("removed", false);
        boolean removed = nestedRemoved || idempotent;
        boolean failed = receipt.optBoolean("failed", false)
            || receipt.optInt("foreignEvents", 0) != 0
            || receipt.optInt("callbackErrors", 0) != 0;
        return new JSONObject().put("closed", removed && !failed)
            .put("removed", removed).put("idempotent", idempotent)
            .put("failed", failed);
    }

    /**
     * Releases the process-owned guard resources once and fences the main
     * looper afterwards, so the receipt describes an actually closed domain.
     */
    private JSONObject releaseSavedContentGuard() throws Exception {
        Class<?> bridge = Class.forName("io.liber.oracle.nested.SelectedFieldHostBridge");
        JSONObject released = (JSONObject) bridge.getMethod("releaseProcessResources").invoke(null);
        JSONObject fence = (JSONObject) bridge.getMethod("fenceMainLooper", long.class)
            .invoke(null, 5000L);
        JSONObject receipt = (JSONObject) bridge.getMethod("captureReceipt").invoke(null);
        JSONObject guard = new JSONObject()
            .put("release", released)
            .put("fence", fence)
            .put("receipt", receipt);
        if (!released.optBoolean("closed", false)) {
            throw new IllegalStateException("the guard did not close every owned resource: " + guard);
        }
        // F2: a fence that was not posted or did not complete is an unproved
        // closure, not a success.
        if (!fence.optBoolean("posted", false) || !fence.optBoolean("completed", false)) {
            throw new IllegalStateException("the main-looper fence did not complete: " + guard);
        }
        if (receipt.optInt("blockedDeliveries", 0) != 0) {
            throw new IllegalStateException("an external IPC attempt reached the guard: " + guard);
        }
        return guard;
    }

    /** Whether the guard recorded a capture failure that must fail this run. */
    private boolean guardCaptureFailed() {
        try {
            Class<?> bridge = Class.forName("io.liber.oracle.nested.SelectedFieldHostBridge");
            return (Boolean) bridge.getMethod("captureFailed").invoke(null);
        } catch (Throwable error) {
            return true;
        }
    }

    /** One guard-owned save-observation phase: begin, end or close. */
    private JSONObject saveObservation(ClassLoader loader, String phase, String bookUrl,
            String chapterUrl) throws Exception {
        Class<?> bridge = Class.forName("io.liber.oracle.nested.SelectedFieldHostBridge");
        switch (phase) {
            case "begin":
                return (JSONObject) bridge.getMethod("beginSaveObservation", String.class,
                    String.class).invoke(null, bookUrl, chapterUrl);
            case "end":
                return (JSONObject) bridge.getMethod("endSaveObservation", long.class)
                    .invoke(null, 15000L);
            default:
                return (JSONObject) bridge.getMethod("endSaveObservation", long.class)
                    .invoke(null, 0L);
        }
    }

    /** The chapter files the content save actually wrote, under the proven root. */
    private JSONArray contentFiles(ClassLoader loader, Class<?> bookClass, Object book)
            throws Exception {
        Class<?> bookHelp = loader.loadClass("io.legado.app.help.book.BookHelp");
        // The selected BookHelp.getCachePath() descriptor is ()Ljava/lang/String;.
        String cacheText = (String) bookHelp.getMethod("getCachePath")
            .invoke(bookHelp.getField("INSTANCE").get(null));
        String folder = (String) bookClass.getMethod("getFolderName").invoke(book);
        File[] files = new File(new File(cacheText), folder).listFiles();
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
     * The approved {@code tocCountWords} lifetime: capture the immutable prior
     * presence and value, apply the value, and restore it on every path.
     *
     * <p>Package-internal so the host controls drive this exact code, not an
     * imitation of it. Standard state only; no new abstraction.
     */
    static final class TocCountWordsLifetime {
        static final String KEY = TOC_COUNT_WORDS;

        /**
         * The whole saved-case lifetime: capture the prior state, acquire the
         * observer, apply the preference, run the operation, then close the
         * observer and restore the preference on every path.
         *
         * <p>The collector delegates its saved case here, so the host controls
         * exercise the same sequence the device does. The prior state is
         * captured before any mutation; a throwing begin still enters the owned
         * cleanup; every cleanup failure is retained with its complete chain and
         * attached to the primary as suppressed.
         */
        static JSONObject run(android.content.SharedPreferences preferences,
                Callable<JSONObject> beginObserver, Callable<JSONObject> operation,
                Callable<JSONObject> closeObserver, JSONObject proof) throws Throwable {
            JSONObject prior = capture(preferences);
            Throwable primary = null;
            JSONObject result = null;
            try {
                if (beginObserver != null) beginObserver.call();
                JSONObject applied = apply(preferences, true);
                if (proof != null) proof.put("tocCountWordsApplied", applied);
                if (operation != null) result = operation.call();
            } catch (Throwable error) {
                primary = error;
            }
            Throwable closeFailure = null;
            JSONObject closeProof = null;
            if (closeObserver != null) {
                try {
                    closeProof = closeObserver.call();
                } catch (Throwable error) {
                    closeFailure = error;
                }
                if (closeFailure == null
                        && (closeProof == null || !closeProof.optBoolean("closed", false))) {
                    closeFailure = new IllegalStateException(
                        "the observer close did not prove a closed domain");
                }
            }
            Throwable restoreFailure = null;
            try {
                JSONObject restored = restore(preferences, prior);
                if (proof != null) proof.put("tocCountWords", restored);
            } catch (Throwable error) {
                restoreFailure = error;
            }
            if (primary != null) {
                if (closeFailure != null) primary.addSuppressed(closeFailure);
                if (restoreFailure != null) primary.addSuppressed(restoreFailure);
                throw primary;
            }
            if (closeFailure != null) {
                if (restoreFailure != null) closeFailure.addSuppressed(restoreFailure);
                throw closeFailure;
            }
            if (restoreFailure != null) throw restoreFailure;
            return result == null ? new JSONObject() : result;
        }

        static JSONObject capture(android.content.SharedPreferences preferences)
                throws Exception {
            return new JSONObject()
                .put("name", KEY)
                .put("previousPresent", preferences.contains(KEY))
                .put("previous", preferences.getBoolean(KEY, true));
        }

        static JSONObject apply(android.content.SharedPreferences preferences, boolean value)
                throws Exception {
            boolean committed = preferences.edit().putBoolean(KEY, value).commit();
            boolean observed = preferences.getBoolean(KEY, true);
            if (!committed || observed != value) {
                throw new IllegalStateException("tocCountWords preference did not take effect");
            }
            return new JSONObject().put("name", KEY).put("applied", value)
                .put("committed", committed).put("observed", observed);
        }

        static JSONObject restore(android.content.SharedPreferences preferences, JSONObject prior)
                throws Exception {
            if (prior == null) {
                throw new IllegalStateException("the prior tocCountWords state was not captured");
            }
            android.content.SharedPreferences.Editor editor = preferences.edit();
            if (prior.getBoolean("previousPresent")) {
                editor.putBoolean(KEY, prior.getBoolean("previous"));
            } else {
                editor.remove(KEY);
            }
            boolean committed = editor.commit();
            boolean present = preferences.contains(KEY);
            boolean observed = preferences.getBoolean(KEY, true);
            boolean restored = committed
                && present == prior.getBoolean("previousPresent")
                && observed == prior.getBoolean("previous");
            JSONObject receipt = new JSONObject()
                .put("previousPresent", prior.getBoolean("previousPresent"))
                .put("committed", committed)
                .put("presentAfter", present)
                .put("observedAfter", observed)
                .put("restored", restored);
            if (!restored) {
                throw new IllegalStateException("tocCountWords was not restored: " + receipt);
            }
            return receipt;
        }
    }

    /** R6: the immutable prior preference state, captured BEFORE any mutation. */
    private JSONObject capturePriorPreference(ClassLoader loader) throws Exception {
        return TocCountWordsLifetime.capture(defaultPreferences(loader));
    }

    /** Applies the approved value and records what was actually observed. */
    private JSONObject applyTocCountWords(ClassLoader loader, boolean value) throws Exception {
        return TocCountWordsLifetime.apply(defaultPreferences(loader), value);
    }

    private JSONObject restoreTocCountWords(ClassLoader loader, JSONObject state)
            throws Exception {
        return TocCountWordsLifetime.restore(defaultPreferences(loader), state);
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
        writeReportFile(output, report);
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
                // F7: request receipt recording and response selection are one
                // bounded ordering boundary, so two concurrent workers cannot be
                // recorded in one order and served in the other.
                JSONObject declared;
                synchronized (requests) {
                    requests.put(observed);
                    stageTrace.put(new JSONObject()
                        .put("stage", stage.get())
                        .put("path", origin + path
                            + (rawQuery.isEmpty() ? "" : "?" + rawQuery)));
                    declared = match(method, path, query);
                }
                OutputStream output = socket.getOutputStream();
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

        /** Called only while holding the {@code requests} lock (see {@code serve}). */
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
