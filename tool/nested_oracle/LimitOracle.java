package io.liber.oracle.nested;

import android.app.ActivityManager;
import android.app.Instrumentation;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Iterator;
import java.util.Locale;
import java.util.TimeZone;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The frozen side of ticket #79's limit probe: runs an accumulate-to-the-limit
 * script through the frozen rule path -- a rule-level {@code @js:} field, which
 * {@code AnalyzeRule.splitSourceRule} hands to {@code AnalyzeRule.evalJS}
 * ({@code AnalyzeRule.kt:749}) and so to {@code RhinoScriptEngine.compile} plus
 * {@code RhinoCompiledScript.eval} -- inside the installed, hash-pinned
 * {@code io.legado.app.debug} process. No Legado class is rebuilt.
 *
 * <p>{@code AnalyzeUrl.evalJS} is the same engine, the same scope plumbing and
 * the same error mapping, but it serves a URL's inline {@code {{js}}} segments
 * and the request options. The rule-level entry is the one a Book Source's own
 * rule field reaches, so it is the behaviour a source log records.
 *
 * <p>The engine caps nothing itself: {@code RhinoScriptEngine}'s factory sets
 * {@code instructionObserverThreshold} and {@code maximumInterpreterStackDepth},
 * and {@code RhinoContext.ensureActive} only asks a coroutine -- no heap cap.
 * The limit is therefore the app's Java heap, and the interesting outcome is
 * the whole process dying at it. Every stage is appended to
 * {@code limit-oracle.journal.ndjson} and fsynced before the next stage starts,
 * and the destructive row runs last: the control rows and the pre-flight rows
 * are already durable when the probe runs.
 *
 * <p>The work is posted to the main looper first, because the target
 * application object (and with it {@code splitties.init.appCtx}, which
 * {@code SharedJsScope} initialises from) is created before this runs.
 */
public final class LimitOracle extends Instrumentation {

    private static final String JOURNAL_FILE = "limit-oracle.journal.ndjson";
    private static final String REPORT_FILE = "limit-oracle.json";
    private static final long WATCHDOG_MILLIS = 900000L;

    private final JSONArray stages = new JSONArray();
    private final JSONArray rows = new JSONArray();
    private final StringBuilder journalText = new StringBuilder();
    private final AtomicReference<String> stage = new AtomicReference<>("onCreate");
    private final AtomicBoolean finished = new AtomicBoolean();

    private File outputDirectory;
    private FileOutputStream journal;
    private JSONObject corpus;

    private Constructor<?> analyzeRuleConstructor;
    private Method setContentMethod;
    private Method getStringMethod;
    private Method sourceLogMethod;
    private Object bookSource;
    private Object ruleData;

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        log("onCreate");
        new Handler(Looper.getMainLooper()).post(() -> {
            log("main looper reached; starting the worker thread");
            new Thread(this::run, "limit-oracle").start();
        });
        startWatchdog();
    }

    /**
     * The accumulating row is unbounded by construction; this only reports. It
     * writes a durable stage and the report before it finishes, so a run that
     * never reaches the limit still leaves the stages it did reach.
     */
    private void startWatchdog() {
        Thread watchdog = new Thread(() -> {
            try {
                Thread.sleep(WATCHDOG_MILLIS);
            } catch (InterruptedException interrupted) {
                return;
            }
            if (finished.compareAndSet(false, true)) {
                record("watchdog-fired", field("stuckStage", stage.get()));
                writeReport();
                Bundle status = new Bundle();
                status.putString("stream", "Limit oracle timed out after "
                    + (WATCHDOG_MILLIS / 1000L) + "s in stage " + stage.get() + "\n");
                finish(1, status);
            }
        }, "limit-oracle-watchdog");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    private void log(String message) {
        Log.i("LimitOracle", message);
    }

    private void run() {
        Bundle status = new Bundle();
        try {
            outputDirectory = getTargetContext().getExternalFilesDir(null);
            journal = new FileOutputStream(new File(outputDirectory, JOURNAL_FILE), true);
            corpus = new JSONObject(readAsset("limit-fixtures.json"));
            record("harness-begin", new JSONObject()
                .put("fixtureId", corpus.getString("fixtureId"))
                .put("ticket", corpus.getString("ticket"))
                .put("baselineCommit", corpus.getString("baselineCommit"))
                .put("entryPoint", corpus.getString("entryPoint"))
                .put("corpusAsset", "limit-fixtures.json")
                .put("corpusSha256", sha256(readAssetBytes("limit-fixtures.json")))
                .put("journalFile", new File(outputDirectory, JOURNAL_FILE).getAbsolutePath()));
            record("device", deviceFacts());
            resolveFrozenEntry();
            record("frozen-entry", new JSONObject()
                .put("analyzeRuleConstructor", analyzeRuleConstructor.toString())
                .put("setContent", setContentMethod.toString())
                .put("getString", getStringMethod.toString())
                .put("sourceClass", bookSource.getClass().getName())
                .put("ruleDataClass", ruleData.getClass().getName())
                .put("jsLib", corpus.getJSONObject("source").getString("jsLib"))
                .put("bookSourceUrl", corpus.getJSONObject("source").getString("bookSourceUrl")));

            // Everything below is row-driven and in the fixture's declared order:
            // the control rows and the pre-flight rows precede the destructive
            // row, and the probe is the fixture's last accumulating row.
            JSONArray declared = corpus.getJSONArray("rows");
            String controlClass = null;
            String probeClass = null;
            String probeOutcome = null;
            for (int index = 0; index < declared.length(); index++) {
                JSONObject row = declared.getJSONObject(index);
                String id = row.getString("id");
                String rule = row.getString("rule");
                stage.set(id);
                boolean destructive = row.optBoolean("destructive", false);
                if (destructive) {
                    // The journal must say this row was entered: the interesting
                    // outcome is that it never returns.
                    record("destructive-begin", new JSONObject()
                        .put("id", id)
                        .put("rule", rule)
                        .put("heap", heapFacts()));
                }
                JSONObject observation = driveRule(id, rule);
                rows.put(observation);
                if (id.equals(corpus.optString("controlRowId"))) {
                    controlClass = observation.optString("errorClass", observation.optString("outcome"));
                }
                record("row", new JSONObject()
                    .put("id", id)
                    .put("destructive", destructive)
                    .put("rule", rule)
                    .put("heap", observation.optJSONObject("heap"))
                    .put("outcome", observation.optString("outcome"))
                    .put("errorClass", observation.optString("errorClass", "")));
                if (destructive) {
                    probeOutcome = observation.optString("outcome");
                    probeClass = observation.optString("errorClass", probeOutcome);
                    // The probe's own record is the one the process may not
                    // outlive, so the assembled report is written now and again
                    // at the end: a death between the two still leaves the
                    // report with the probe's outcome in it.
                    writeReport();
                }
            }
            record("harness-end", new JSONObject()
                .put("rows", rows.length())
                .put("controlClass", controlClass == null ? JSONObject.NULL : controlClass)
                .put("probeClass", probeClass == null ? JSONObject.NULL : probeClass));
            writeReport();
            stage.set("done");
            log("report written; control=" + controlClass + " probe=" + probeClass);
            status.putString("stream", "Limit oracle recorded " + rows.length()
                + " rows; throw-null control=" + controlClass
                + "; accumulate row=" + probeOutcome + " (" + probeClass + ")\n");
            finished.set(true);
            finish(-1, status);
        } catch (Throwable error) {
            status.putString("stream", "Limit oracle harness error: " + describe(error) + "\n");
            log("harness error: " + describe(error));
            record("harness-error", field("error", describe(error)));
            writeReport();
            finished.set(true);
            finish(1, status);
        }
    }

    /** One rule field through the frozen rule path, in its own scope. */
    private JSONObject driveRule(String id, String rule) throws Exception {
        JSONObject observation = new JSONObject().put("id", id).put("rule", rule);
        Object analyzeRule = null;
        try {
            analyzeRule = newAnalyzeRule();
        } catch (Throwable error) {
            observation.put("outcome", "harness-error").put("error", describe(error));
            return observation;
        }
        long started = System.nanoTime();
        try {
            Object value = getStringMethod.invoke(analyzeRule, rule, null, Boolean.FALSE);
            observation.put("outcome", "value")
                .put("value", abbreviate(value == null ? "null" : String.valueOf(value), 200));
        } catch (InvocationTargetException error) {
            Throwable observed = error.getCause() == null ? error : error.getCause();
            observation.put("outcome", "error").put("thrownBy", "rule-path");
            putThrowable(observation, observed);
        } catch (Throwable error) {
            // The heap limit's own case can arrive unwrapped: the wrapper the
            // reflection call needs is one more allocation. An Error is the rule
            // path's; anything else here is harness plumbing, recorded by class.
            observation.put("outcome", "error")
                .put("thrownBy", error instanceof Error ? "rule-path-unwrapped" : "reflection");
            putThrowable(observation, error);
        }
        observation.put("elapsedMillis", (System.nanoTime() - started) / 1000000L);
        observation.put("heap", heapFacts());
        return observation;
    }

    private Object newAnalyzeRule() throws Exception {
        Object analyzeRule = analyzeRuleConstructor.newInstance(ruleData, bookSource);
        setContentMethod.invoke(analyzeRule, corpus.getString("content"),
            corpus.getJSONObject("source").getString("bookSourceUrl"));
        return analyzeRule;
    }

    private void resolveFrozenEntry() throws Exception {
        ClassLoader loader = getTargetContext().getClassLoader();
        Class<?> sourceClass = loader.loadClass("io.legado.app.data.entities.BookSource");
        Class<?> ruleDataClass = loader.loadClass("io.legado.app.model.analyzeRule.RuleData");
        Class<?> ruleDataInterface = loader.loadClass("io.legado.app.model.analyzeRule.RuleDataInterface");
        Class<?> baseSourceClass = loader.loadClass("io.legado.app.data.entities.BaseSource");
        analyzeRuleConstructor = loader.loadClass("io.legado.app.model.analyzeRule.AnalyzeRule")
            .getConstructor(ruleDataInterface, baseSourceClass);
        Class<?> analyzeRuleClass = analyzeRuleConstructor.getDeclaringClass();
        setContentMethod = analyzeRuleClass.getMethod("setContent", Object.class, String.class);
        getStringMethod = analyzeRuleClass.getMethod("getString", String.class, Object.class, Boolean.TYPE);
        Object source = sourceClass.getConstructor().newInstance();
        sourceClass.getMethod("setBookSourceUrl", String.class)
            .invoke(source, corpus.getJSONObject("source").getString("bookSourceUrl"));
        sourceClass.getMethod("setJsLib", String.class)
            .invoke(source, corpus.getJSONObject("source").getString("jsLib"));
        bookSource = source;
        ruleData = ruleDataClass.getConstructor().newInstance();
    }

    private JSONObject deviceFacts() throws Exception {
        Runtime runtime = Runtime.getRuntime();
        ActivityManager manager =
            (ActivityManager) getTargetContext().getSystemService(Context.ACTIVITY_SERVICE);
        ApplicationInfo installed = getTargetContext().getApplicationInfo();
        File apk = new File(installed.sourceDir);
        return new JSONObject()
            .put("model", Build.MODEL)
            .put("fingerprint", Build.FINGERPRINT)
            .put("androidRelease", Build.VERSION.RELEASE)
            .put("sdk", Build.VERSION.SDK_INT)
            .put("javaVmVersion", String.valueOf(System.getProperty("java.vm.version")))
            .put("targetPackage", getTargetContext().getPackageName())
            .put("targetProcessId", android.os.Process.myPid())
            .put("largeHeapDeclared",
                (installed.flags & ApplicationInfo.FLAG_LARGE_HEAP) != 0)
            .put("memoryClassMb", manager == null ? -1 : manager.getMemoryClass())
            .put("largeMemoryClassMb", manager == null ? -1 : manager.getLargeMemoryClass())
            .put("installedApk", apk.getAbsolutePath())
            .put("installedApkBytes", apk.length())
            .put("runtimeMaxMemoryBytes", runtime.maxMemory())
            .put("runtimeTotalMemoryBytes", runtime.totalMemory())
            .put("runtimeFreeMemoryBytes", runtime.freeMemory())
            .put("webView", webViewFacts());
    }

    /** The System WebView the platform resolves; recorded for the device block. */
    private JSONObject webViewFacts() throws Exception {
        try {
            PackageManager packages = getTargetContext().getPackageManager();
            for (String name : new String[]{
                "com.google.android.webview", "com.android.webview", "com.android.chrome"}) {
                try {
                    PackageInfo info = packages.getPackageInfo(name, 0);
                    return new JSONObject()
                        .put("package", name)
                        .put("versionName", String.valueOf(info.versionName))
                        .put("versionCode", info.getLongVersionCode());
                } catch (Throwable absent) {
                    // Try the next provider.
                }
            }
        } catch (Throwable error) {
            return new JSONObject().put("package", JSONObject.NULL)
                .put("error", describe(error));
        }
        return new JSONObject().put("package", JSONObject.NULL);
    }

    private JSONObject heapFacts() throws Exception {
        Runtime runtime = Runtime.getRuntime();
        return new JSONObject()
            .put("maxBytes", runtime.maxMemory())
            .put("totalBytes", runtime.totalMemory())
            .put("freeBytes", runtime.freeMemory())
            .put("usedBytes", runtime.totalMemory() - runtime.freeMemory());
    }

    private void putThrowable(JSONObject observation, Throwable observed) {
        try {
            observation.put("errorClass", observed.getClass().getName());
            observation.put("errorMessage", abbreviate(String.valueOf(observed.getMessage()), 400));
            JSONArray causes = new JSONArray();
            Throwable cause = observed.getCause();
            int depth = 0;
            while (cause != null && depth < 6) {
                causes.put(cause.getClass().getName()
                    + (cause.getMessage() == null ? "" : ": " + abbreviate(cause.getMessage(), 200)));
                cause = cause.getCause();
                depth++;
            }
            observation.put("causes", causes);
            StackTraceElement[] frames = observed.getStackTrace();
            JSONArray head = new JSONArray();
            for (int index = 0; index < frames.length && index < 12; index++) {
                head.put(frames[index].toString());
            }
            observation.put("stackHead", head);
            observation.put("stackDepth", frames.length);
            observation.put("sourceLog", sourceLog(observed));
        } catch (Throwable error) {
            log("putThrowable failed: " + describe(error));
        }
    }

    /**
     * The exact string the frozen source log records for a failed analysis:
     * {@code Debug.log(source, it.stackTraceStr, state = -1)} with
     * {@code Throwable.stackTraceStr} ({@code ThrowableExtensions.kt:5}). It
     * allocates, so it is called after the throwable has unwound and its own
     * failure is recorded rather than propagated.
     */
    private String sourceLog(Throwable observed) {
        try {
            if (sourceLogMethod == null) {
                sourceLogMethod = getTargetContext().getClassLoader()
                    .loadClass("io.legado.app.utils.ThrowableExtensionsKt")
                    .getMethod("getStackTraceStr", Throwable.class);
            }
            Object text = sourceLogMethod.invoke(null, observed);
            return text == null ? null : abbreviate(String.valueOf(text), 4000);
        } catch (Throwable error) {
            return "unavailable: " + describe(error);
        }
    }

    private String readAsset(String name) throws IOException {
        return new String(readAssetBytes(name), StandardCharsets.UTF_8);
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

    private static String sha256(byte[] bytes) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            StringBuilder text = new StringBuilder(digest.length * 2);
            for (byte value : digest) text.append(String.format(Locale.US, "%02x", value));
            return text.toString();
        } catch (Exception error) {
            return "unavailable: " + error;
        }
    }

    /**
     * Appends one stage record and fsyncs it. The record is single-line JSON so
     * the journal file is the run's durable prefix even when the process dies
     * mid-row: the last line is the last stage that was reached.
     */
    private synchronized void record(String name, JSONObject fields) {
        try {
            JSONObject record = new JSONObject().put("stage", name).put("at", timestamp());
            Iterator<String> keys = fields.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                record.put(key, fields.get(key));
            }
            stages.put(record);
            String line = record.toString();
            journalText.append(line).append('\n');
            if (journal != null) {
                journal.write((line + "\n").getBytes(StandardCharsets.UTF_8));
                journal.flush();
                journal.getFD().sync();
            }
            log("stage=" + name + " " + line);
        } catch (Throwable error) {
            log("record failed: " + describe(error));
        }
    }

    private void writeReport() {
        try {
            JSONObject report = new JSONObject()
                .put("kind", "frozen-limit-probe")
                .put("fixtureId", corpus.getString("fixtureId"))
                .put("ticket", corpus.getString("ticket"))
                .put("baselineCommit", corpus.getString("baselineCommit"))
                .put("entryPoint", corpus.getString("entryPoint"))
                .put("platform", "android")
                .put("fingerprint", Build.FINGERPRINT)
                .put("recordedAt", timestamp())
                .put("lastStage", stage.get())
                .put("device", deviceFactsQuietly())
                .put("rows", rows)
                .put("stages", stages)
                .put("journal", journalText.toString());
            File reportFile = new File(outputDirectory, REPORT_FILE);
            try (FileOutputStream stream = new FileOutputStream(reportFile)) {
                stream.write(report.toString(2).getBytes(StandardCharsets.UTF_8));
                stream.flush();
                stream.getFD().sync();
            }
        } catch (Throwable error) {
            log("writeReport failed: " + describe(error));
        }
    }

    private JSONObject deviceFactsQuietly() {
        try {
            return deviceFacts();
        } catch (Throwable error) {
            return field("error", describe(error));
        }
    }

    /**
     * One-field JSON without a checked-exception signature, so a stage body can
     * be built from a catch block: an empty object is recorded rather than
     * losing the stage.
     */
    private static JSONObject field(String key, Object value) {
        try {
            return new JSONObject().put(key, value);
        } catch (Throwable error) {
            return new JSONObject();
        }
    }

    private static String abbreviate(String text, int limit) {
        if (text == null) return null;
        if (text.length() <= limit) return text;
        return text.substring(0, limit) + "...(length=" + text.length() + ")";
    }

    private static String timestamp() {
        SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return format.format(new Date());
    }

    private static String describe(Throwable error) {
        StringBuilder text = new StringBuilder(error.getClass().getName()
            + (error.getMessage() == null ? "" : ": " + error.getMessage()));
        Throwable cause = error.getCause();
        int depth = 0;
        while (cause != null && depth < 6) {
            text.append(" <- ").append(cause);
            cause = cause.getCause();
            depth++;
        }
        return text.toString();
    }
}
