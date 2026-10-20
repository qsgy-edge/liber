package io.liber.oracle.nested;

import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.database.Cursor;
import android.database.DatabaseErrorHandler;
import android.database.sqlite.SQLiteDatabase;
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
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Array;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TimeZone;
import java.util.TreeSet;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The frozen side of the STATE-SESSION-01 corpus: drives
 * {@code io.legado.app.model.webBook.WebBook}'s four suspend entry points against the
 * installed, hash-pinned {@code io.legado.app.debug}, publishes the returned entities
 * through the same frozen call sites the detail page uses, and serves
 * {@code tool/state_session/fixtures.json} on the port the corpus names, inside this
 * process. No Legado class is rebuilt and no row is written directly.
 *
 * <p>The two phases are two process lifetimes. {@code -e phase seed} creates a fresh
 * task-owned scratch installation, records the source variables, book variables,
 * chapter variables and content reads, closes the database and the replay server and
 * <em>retains</em> the scratch so a restart can observe it. {@code -e phase restart}
 * requires the owner manifest the seed left behind, reads the persisted rows back,
 * refreshes the two books that declare a second TOC revision and removes the scratch
 * root and the preference files the seed owned.
 *
 * <p>Mechanisms reused rather than reinvented: {@code SliceOracle.java}'s four-stage
 * reflection driver (suspend bridge, name-prefix lookup, {@code kotlin.Result} unboxing)
 * and {@code ReplaceJsOracle.java}'s storage-only {@code Application} plus
 * {@code ScratchContext}, which keeps the installed application's own database and
 * preferences out of reach. The report leaves through the BASE64 instrumentation stream,
 * so a successful cleanup cannot delete the evidence it reports.
 *
 * <p>Frozen call sites (baseline {@code 14dd24945b2914ce2708b8abaa4ee67ceef892af}):
 * {@code WebBook.kt:48-88,152-198,224-270,296-355}; {@code Book.save()} at
 * {@code Book.kt:367-373}; the detail page's publication sequence at
 * {@code BookInfoViewModel.kt:238,245-246} over {@code BookChapterDao.kt:35,41};
 * variable access at {@code BaseSource.kt:202-230} and {@code AnalyzeRule.kt:718-771}.
 */
public final class StateSessionOracle extends Instrumentation {

    private static final String ASSET = "state-session-fixtures.json";
    private static final String STREAM_KEY = "STATE_SESSION_ORACLE_BASE64";
    private static final String PREFERENCE_PREFIX = "liber_state_session_01_";
    private static final String SCRATCH_ROOT_NAME = "liber-state-session-01";
    private static final String OWNER_FILE = "owner.json";

    private final JSONArray requests = new JSONArray();
    private final JSONArray unmatched = new JSONArray();
    private final JSONArray serverErrors = new JSONArray();
    private final JSONArray stageTrace = new JSONArray();
    private final JSONArray observations = new JSONArray();
    private final JSONObject inventory = new JSONObject();
    private final AtomicReference<String> stage = new AtomicReference<>("setup");
    private final AtomicBoolean finished = new AtomicBoolean();

    private ScratchContext scratch;
    private String phase;
    private String runId;
    private JSONObject corpus;
    private JSONObject phaseSpec;
    private StateReplay replay;
    private Object database;
    private Object bookChapterDao;
    private ClassLoader loader;

    @Override
    public Application newApplication(ClassLoader cl, String name, Context context)
            throws InstantiationException, IllegalAccessException, ClassNotFoundException {
        scratch = new ScratchContext(context);
        return super.newApplication(cl, Application.class.getName(), scratch);
    }

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        // The phase arrives as `am instrument -e phase <seed|restart>`. It is read here
        // because nothing may reach storage until the phase is known.
        if (args != null) phase = args.getString("phase");
        log("onCreate phase=" + phase);
        new Handler(Looper.getMainLooper()).post(() -> {
            log("main looper reached; starting the worker thread");
            new Thread(this::run, "state-session-oracle").start();
        });
        startWatchdog();
    }

    private void startWatchdog() {
        Thread watchdog = new Thread(() -> {
            try {
                Thread.sleep(240000);
            } catch (InterruptedException interrupted) {
                return;
            }
            if (finished.compareAndSet(false, true)) {
                log("watchdog: no result after 240s; stage=" + stage.get());
                Bundle status = new Bundle();
                status.putString("stream", "State session oracle timed out in stage " + stage.get()
                    + " after " + requests.length() + " requests\n");
                finish(1, status);
            }
        }, "state-session-watchdog");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    private void log(String message) {
        Log.i("StateSessionOracle", message);
    }

    private void run() {
        Bundle status = new Bundle();
        JSONObject report = new JSONObject();
        boolean ok = false;
        String failure = null;
        JSONObject cleanup = new JSONObject();
        try {
            runId = UUID.randomUUID().toString();
            corpus = new JSONObject(new String(readAsset(ASSET), StandardCharsets.UTF_8));
            if (!"seed".equals(phase) && !"restart".equals(phase)) {
                throw new IllegalStateException("phase must be seed or restart, got " + phase);
            }
            phaseSpec = corpus.getJSONObject("phases").getJSONObject(phase);
            log("corpus " + corpus.getString("fixtureId") + " phase " + phase);

            // Identity first: target, corpus and harness bytes are measured and compared
            // with the corpus pin before any storage callback can reach data.
            JSONObject identity = measureIdentity();
            report.put("fixtureId", corpus.getString("fixtureId"))
                .put("corpusVersion", corpus.getInt("corpusVersion"))
                .put("schemaVersion", corpus.getInt("schemaVersion"))
                .put("baselineCommit", corpus.getString("baselineCommit"))
                .put("entryPoint", corpus.getString("entryPoint"))
                .put("platform", "android")
                .put("fingerprint", Build.FINGERPRINT)
                .put("recordedAt", timestamp())
                .put("phase", phase)
                .put("runId", runId)
                .put("pid", android.os.Process.myPid())
                .put("identity", identity);

            // Storage: a fresh owned root for the seed, the validated owned root for the
            // restart. Both are settled before the room database is opened.
            scratch.bind(phase, identity);
            report.put("isolation", checkIsolation());
            log("isolation ok");
            database = loader.loadClass("io.legado.app.data.AppDatabaseKt")
                .getMethod("getAppDb").invoke(null);
            bookChapterDao = call(database, "getBookChapterDao");

            replay = new StateReplay(corpus, phase, requests, unmatched, serverErrors,
                stageTrace, stage);
            replay.start();
            log("replay server bound to " + replay.origin());

            drive();
            ok = true;
        } catch (Throwable error) {
            failure = describe(error);
            log("phase " + phase + " failed in stage " + stage.get() + ": " + failure);
        } finally {
            stage.set("cleanup");
            try {
                cleanup = cleanup(ok);
            } catch (Throwable error) {
                ok = false;
                if (failure == null) failure = "cleanup: " + describe(error);
                try {
                    cleanup.put("cleanupFailure", describe(error));
                } catch (JSONException ignored) {
                    // The report below still carries the failure text.
                }
            }
            try {
                report.put("stageTrace", stageTrace)
                    .put("requests", requests)
                    .put("unmatchedRequests", unmatched)
                    .put("serverErrors", serverErrors)
                    .put("requestCheck", requestCheck())
                    .put("observations", observations)
                    .put("observationCheck", observationCheck())
                    .put("inventory", inventory)
                    .put("cleanup", cleanup)
                    .put("analysisFailure", failure == null ? JSONObject.NULL : failure);
            } catch (Throwable error) {
                ok = false;
                failure = (failure == null ? "" : failure + " | ")
                    + "report assembly: " + describe(error);
                log("report assembly failed: " + describe(error));
            }
            status.putString("stream", STREAM_KEY + "=" + base64(report.toString())
                + "\nState session oracle " + phase + ": "
                + (failure == null ? "recorded " + requests.length() + " requests, "
                    + observations.length() + " observations" : "failed: " + failure) + "\n");
            log("report assembled; failure=" + failure);
            finished.set(true);
            finish(ok ? -1 : 1, status);
        }
    }

    // ---------------------------------------------------------------- identity

    /**
     * Measures the installed target, the harness APK and the corpus asset, and refuses
     * when the corpus pin disagrees. Only package metadata and the two APK files are read.
     */
    private JSONObject measureIdentity() throws Exception {
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
        byte[] asset = readAsset(ASSET);
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
            .put("corpusSha256Lf", sha256(lf(asset)));
    }

    /**
     * The frozen application's storage callbacks have to land in the scratch root. A path
     * that escaped would mean the installed user data were in reach, so it is a refusal.
     */
    private JSONObject checkIsolation() throws Exception {
        loader = getTargetContext().getClassLoader();
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
        // The frozen code reaches preferences through PreferenceManager, which asks the
        // application context by name. Two files could answer that: the task-prefixed one
        // this harness owns, and the installation's own, which must never appear.
        File dataDir = new File(getTargetContext().getApplicationInfo().dataDir, "shared_prefs");
        JSONObject probe = scratch.probePreferences(app, dataDir, "liber_state_session_probe");
        if (probe.getBoolean("installationFile")
                || !probe.getBoolean("scopedRegistered")
                || !probe.getBoolean("scopedFile")) {
            throw new IllegalStateException("appCtx preference storage is not scratch-scoped: "
                + probe);
        }
        return new JSONObject()
            .put("application", app.getClass().getName())
            .put("files", app.getFilesDir().toString())
            .put("database", app.getDatabasePath("legado.db").toString())
            .put("preferencesPrefix", PREFERENCE_PREFIX)
            .put("preferencesLocation", corpus.getJSONObject("scratch")
                .getString("preferencesLocation"))
            .put("preferenceProbe", probe)
            .put("scratchRoot", scratch.root.getAbsolutePath())
            .put("scratchRootExistedAtStart", scratch.rootExistedAtStart())
            .put("scratchCreatedByThisRun", "seed".equals(phase))
            .put("scratchRetainedFromSeed", "restart".equals(phase))
            .put("frozenAppOnCreate",
                "not-run: newApplication returns a storage-only android.app.Application, so"
                    + " io.legado.app.App.onCreate (crash handler, file logging, cronet"
                    + " pre-download, DefaultData.upVersion, freeze monitor, LiveEventBus) does not"
                    + " run; the splitties AppCtxInitProvider does run and is what this check"
                    + " measures");
    }

    // ------------------------------------------------------------------ driving

    /** Walks the corpus' declared steps for this phase, in their declared order. */
    private void drive() throws Throwable {
        JSONArray steps = phaseSpec.getJSONArray("steps");
        Map<String, Object> sources = loadSources();
        Map<String, Object> books = new LinkedHashMap<>();
        Map<String, Map<String, Object>> chapters = new LinkedHashMap<>();
        for (int index = 0; index < steps.length(); index++) {
            JSONObject step = steps.getJSONObject(index);
            String id = step.getString("id");
            String kind = step.getString("kind");
            stage.set(id);
            log("step " + id + " (" + kind + ")");
            switch (kind) {
                case "search":
                    stepSearch(step, sources, books);
                    break;
                case "details":
                    stepDetails(step, sources, books);
                    break;
                case "toc":
                    stepToc(step, sources, books, chapters);
                    break;
                case "content":
                    stepContent(step, sources, books, chapters);
                    break;
                case "state":
                    stepState(step);
                    break;
                default:
                    throw new IllegalStateException("unknown step kind " + kind + " in " + id);
            }
        }
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
            // The library text travels beside the source JSON so the corpus keeps the two
            // separable; it is the source's own jsLib field the frozen reads.
            sourceJson.put("jsLib", entry.getString("jsLib"));
            Object source = fromJson.invoke(gson, sourceJson.toString(), bookSourceClass);
            String key = str(bookSourceClass, source, "getBookSourceUrl");
            if (!key.equals(sourceJson.getString("bookSourceUrl"))) {
                throw new IllegalStateException("source " + entry.getString("id")
                    + " deserialised with a different key: " + key);
            }
            sources.put(entry.getString("id"), source);
        }
        return sources;
    }

    private void stepSearch(JSONObject step, Map<String, Object> sources,
            Map<String, Object> books) throws Throwable {
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        Class<?> searchBookClass = loader.loadClass("io.legado.app.data.entities.SearchBook");
        Object source = require(sources, step.getString("source"), "source");
        String keyword = corpus.getString("keyword");
        Object result = runSuspend(loader, continuation -> call(webBookClass, webBook,
            "searchBookAwait", 6,
            new Object[]{source, keyword, Integer.valueOf(1), null, null}, continuation));
        if (!(result instanceof List)) {
            throw new IllegalStateException("search returned " + result);
        }
        List<?> results = (List<?>) result;
        JSONArray declaredBooks = step.getJSONArray("books");
        if (results.size() < declaredBooks.length()) {
            throw new IllegalStateException("search returned " + results.size()
                + " results for " + declaredBooks.length() + " declared books");
        }
        JSONArray observed = new JSONArray();
        for (int index = 0; index < declaredBooks.length(); index++) {
            Object item = results.get(index);
            observed.put(new JSONObject()
                .put("name", str(searchBookClass, item, "getName"))
                .put("author", str(searchBookClass, item, "getAuthor"))
                .put("kind", str(searchBookClass, item, "getKind"))
                .put("bookUrl", str(searchBookClass, item, "getBookUrl")));
        }
        observations.put(new JSONObject().put("id", step.getString("id"))
            .put("value", new JSONObject().put("results", observed)));
        for (int index = 0; index < declaredBooks.length(); index++) {
            String bookId = declaredBooks.getString(index);
            JSONObject declared = declaredBook(bookId);
            Object book = searchBookClass.getMethod("toBook").invoke(results.get(index));
            String bookUrl = str(book.getClass(), book, "getBookUrl");
            if (!bookUrl.equals(declared.getString("bookUrl"))) {
                throw new IllegalStateException("search result " + index + " is " + bookUrl
                    + ", corpus declares " + declared.getString("bookUrl"));
            }
            books.put(bookId, book);
        }
    }

    private void stepDetails(JSONObject step, Map<String, Object> sources,
            Map<String, Object> books) throws Throwable {
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        Class<?> bookClass = loader.loadClass("io.legado.app.data.entities.Book");
        String bookId = step.getString("book");
        JSONObject declared = declaredBook(bookId);
        Object source = require(sources, declared.getString("source"), "source");
        Object book;
        if ("row".equals(step.getString("from"))) {
            // The reopened process loads the book exactly as the detail page does.
            book = call(call(database, "getBookDao"), "getBook",
                declared.getString("bookUrl"));
            if (book == null) {
                throw new IllegalStateException("no persisted book row for " + bookId
                    + " at " + declared.getString("bookUrl"));
            }
        } else {
            book = require(books, bookId, "book");
        }
        String bookUrl = str(bookClass, book, "getBookUrl");
        if (!bookUrl.equals(declared.getString("bookUrl"))) {
            throw new IllegalStateException("details " + bookId + " has bookUrl " + bookUrl);
        }
        runSuspend(loader, continuation -> call(webBookClass, webBook, "getBookInfoAwait", 4,
            new Object[]{source, book, Boolean.TRUE}, continuation));
        // BookInfoViewModel.kt:400,438: the detail page's own save.
        call(book, "save");
        books.put(bookId, book);
        observations.put(new JSONObject().put("id", step.getString("id"))
            .put("value", new JSONObject()
                .put("bookUrl", bookUrl)
                .put("name", str(bookClass, book, "getName"))
                .put("variable", variableOf(book))
                .put("variableRaw", variableTextOf(book))));
    }

    private void stepToc(JSONObject step, Map<String, Object> sources,
            Map<String, Object> books, Map<String, Map<String, Object>> chapters)
            throws Throwable {
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        Class<?> chapterClass = loader.loadClass("io.legado.app.data.entities.BookChapter");
        String bookId = step.getString("book");
        JSONObject declared = declaredBook(bookId);
        Object source = require(sources, declared.getString("source"), "source");
        Object book = require(books, bookId, "book");
        String bookUrl = declared.getString("bookUrl");
        Object result = runSuspend(loader, continuation -> call(webBookClass, webBook,
            "getChapterListAwait", 4,
            new Object[]{source, book, Boolean.FALSE}, continuation));
        List<?> list = unwrapResult(result);
        if (list.isEmpty()) {
            throw new IllegalStateException("table of contents for " + bookId + " is empty");
        }
        // BookInfoViewModel.kt:238,245-246: the book row, then this book's chapter rows.
        call(book, "save");
        chapterDelete(bookUrl);
        chapterInsert(list);
        Map<String, Object> byUrl = new LinkedHashMap<>();
        JSONArray observed = new JSONArray();
        for (Object chapter : list) {
            String url = str(chapterClass, chapter, "getUrl");
            byUrl.put(url, chapter);
            observed.put(new JSONObject()
                .put("url", url)
                .put("title", str(chapterClass, chapter, "getTitle"))
                .put("tag", str(chapterClass, chapter, "getTag"))
                .put("variable", variableOf(chapter))
                .put("variableRaw", variableTextOf(chapter)));
        }
        chapters.put(bookId, byUrl);
        observations.put(new JSONObject().put("id", step.getString("id"))
            .put("value", new JSONObject()
                .put("revision", step.getInt("revision"))
                .put("chapters", observed)));
    }

    private void stepContent(JSONObject step, Map<String, Object> sources,
            Map<String, Object> books, Map<String, Map<String, Object>> chapters)
            throws Throwable {
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        String bookId = step.getString("book");
        JSONObject declared = declaredBook(bookId);
        Object source = require(sources, declared.getString("source"), "source");
        Object book = require(books, bookId, "book");
        Map<String, Object> byUrl = chapters.get(bookId);
        if (byUrl == null) {
            throw new IllegalStateException("no table of contents read for " + bookId);
        }
        String chapterUrl = step.getString("chapter");
        Object chapter = byUrl.get(chapterUrl);
        if (chapter == null) {
            throw new IllegalStateException("chapter " + chapterUrl
                + " is not in the table of contents of " + bookId);
        }
        // needSave=false: the content stage may not mutate entity state in this corpus.
        Object text = runSuspend(loader, continuation -> call(webBookClass, webBook,
            "getContentAwait", 6,
            new Object[]{source, book, chapter, null, Boolean.FALSE}, continuation));
        observations.put(new JSONObject().put("id", step.getString("id"))
            .put("value", text == null ? "" : text.toString()));
    }

    private void stepState(JSONObject step) throws Exception {
        String surface = step.getString("surface");
        JSONObject value;
        JSONArray rows;
        switch (surface) {
            case "books": {
                Object bookDao = call(database, "getBookDao");
                Class<?> bookClass = loader.loadClass("io.legado.app.data.entities.Book");
                value = new JSONObject();
                JSONArray declared = corpus.getJSONArray("books");
                for (int index = 0; index < declared.length(); index++) {
                    String url = declared.getJSONObject(index).getString("bookUrl");
                    Object row = call(bookDao, "getBook", url);
                    if (row == null) {
                        value.put(url, new JSONObject().put("present", false));
                        continue;
                    }
                    value.put(url, new JSONObject()
                        .put("present", true)
                        .put("name", str(bookClass, row, "getName"))
                        .put("variable", variableOf(row))
                        .put("variableRaw", variableTextOf(row)));
                }
                rows = inventoryRows("select bookUrl from books order by bookUrl");
                break;
            }
            case "chapters": {
                Class<?> chapterClass = loader.loadClass(
                    "io.legado.app.data.entities.BookChapter");
                value = new JSONObject();
                JSONArray declared = corpus.getJSONArray("books");
                for (int index = 0; index < declared.length(); index++) {
                    String url = declared.getJSONObject(index).getString("bookUrl");
                    List<?> rowsForBook = (List<?>) call(bookChapterDao, "getChapterList", url);
                    JSONArray series = new JSONArray();
                    for (Object row : rowsForBook) {
                        series.put(new JSONObject()
                            .put("url", str(chapterClass, row, "getUrl"))
                            .put("title", str(chapterClass, row, "getTitle"))
                            .put("index", ((Number) invokeGetter(chapterClass, row, "getIndex"))
                                .intValue())
                            .put("tag", str(chapterClass, row, "getTag"))
                            .put("variable", variableOf(row))
                            .put("variableRaw", variableTextOf(row)));
                    }
                    value.put(url, series);
                }
                rows = inventoryRows(
                    "select bookUrl, url, `index` from chapters order by bookUrl, `index`");
                break;
            }
            case "caches": {
                Object cacheDao = call(database, "getCacheDao");
                Class<?> cacheClass = loader.loadClass("io.legado.app.data.entities.Cache");
                value = new JSONObject();
                JSONArray keys = corpus.getJSONArray("cacheKeys");
                for (int index = 0; index < keys.length(); index++) {
                    String key = keys.getString(index);
                    Object row = call(cacheDao, "get", key);
                    if (row == null) {
                        value.put(key, new JSONObject().put("present", false));
                        continue;
                    }
                    value.put(key, new JSONObject()
                        .put("present", true)
                        .put("value", str(cacheClass, row, "getValue"))
                        .put("deadline", ((Number) invokeGetter(cacheClass, row, "getDeadline"))
                            .longValue()));
                }
                rows = inventoryRows("select `key` from caches order by `key`");
                break;
            }
            default:
                throw new IllegalStateException("unknown state surface " + surface);
        }
        inventory.put(step.getString("id"), rows);
        observations.put(new JSONObject().put("id", step.getString("id")).put("value", value));
    }

    /**
     * A whole-table key inventory through the frozen Room instance, inside the verified
     * scratch database. It is a receipt for isolation, never a compared observation; the
     * compared state above is read back through the frozen DAOs.
     */
    private JSONArray inventoryRows(String sql) throws Exception {
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

    private void chapterDelete(String bookUrl) throws Exception {
        Method target = null;
        for (Method candidate : bookChapterDao.getClass().getMethods()) {
            if (!candidate.getName().equals("delByBook") || candidate.getParameterCount() != 1) {
                continue;
            }
            if (candidate.getParameterTypes()[0].equals(String.class)) target = candidate;
        }
        if (target == null) throw new IllegalStateException("frozen DAO entry absent: delByBook");
        target.invoke(bookChapterDao, bookUrl);
    }

    private void chapterInsert(List<?> chapters) throws Exception {
        Class<?> chapterClass = loader.loadClass("io.legado.app.data.entities.BookChapter");
        Method target = null;
        for (Method candidate : bookChapterDao.getClass().getMethods()) {
            if (!candidate.getName().equals("insert") || candidate.getParameterCount() != 1) {
                continue;
            }
            if (!candidate.getParameterTypes()[0].isArray()) continue;
            target = candidate;
        }
        if (target == null) throw new IllegalStateException("frozen DAO entry absent: insert");
        Object array = Array.newInstance(chapterClass, chapters.size());
        for (int index = 0; index < chapters.size(); index++) {
            Array.set(array, index, chapters.get(index));
        }
        target.invoke(bookChapterDao, array);
    }

    private JSONObject declaredBook(String bookId) throws JSONException {
        JSONArray declared = corpus.getJSONArray("books");
        for (int index = 0; index < declared.length(); index++) {
            JSONObject book = declared.getJSONObject(index);
            if (book.getString("id").equals(bookId)) return book;
        }
        throw new IllegalStateException("corpus declares no book " + bookId);
    }

    private static Object require(Map<String, Object> map, String id, String what) {
        Object value = map.get(id);
        if (value == null) throw new IllegalStateException("no " + what + " bound for " + id);
        return value;
    }

    /** The parsed variable column, or JSON null when the entity carries none. */
    private static Object variableOf(Object entity) {
        String raw = variableTextOf(entity);
        if (raw == null || raw.isEmpty()) return JSONObject.NULL;
        try {
            return new JSONObject(raw);
        } catch (JSONException error) {
            return JSONObject.NULL;
        }
    }

    private static String variableTextOf(Object entity) {
        try {
            Object value = entity.getClass().getMethod("getVariable").invoke(entity);
            return value == null ? null : value.toString();
        } catch (Exception error) {
            throw new IllegalStateException("frozen variable getter absent", error);
        }
    }

    // ------------------------------------------------------------------- checks

    private JSONObject requestCheck() throws JSONException {
        JSONArray expected = phaseSpec.getJSONArray("expectedRequests");
        JSONObject check = new JSONObject()
            .put("declared", expected)
            .put("declaredCount", expected.length())
            .put("actualCount", requests.length());
        int mismatch = -1;
        for (int index = 0; index < expected.length(); index++) {
            if (index >= requests.length()) {
                mismatch = index;
                break;
            }
            if (!sameRequest(expected.getJSONObject(index), requests.getJSONObject(index))) {
                mismatch = index;
                break;
            }
        }
        if (mismatch < 0 && requests.length() != expected.length()) mismatch = expected.length();
        check.put("match", mismatch < 0)
            .put("mismatchIndex", mismatch < 0 ? JSONObject.NULL : mismatch);
        return check;
    }

    private static boolean sameRequest(JSONObject declared, JSONObject actual)
            throws JSONException {
        if (!declared.getString("method").equals(actual.optString("method"))) return false;
        if (!declared.getString("path").equals(actual.optString("path"))) return false;
        JSONObject declaredQuery = declared.optJSONObject("query");
        JSONObject actualQuery = actual.optJSONObject("query");
        if (declaredQuery == null) {
            return actualQuery == null || actualQuery.length() == 0;
        }
        if (actualQuery == null || declaredQuery.length() != actualQuery.length()) return false;
        Iterator<String> names = declaredQuery.keys();
        while (names.hasNext()) {
            String name = names.next();
            if (!declaredQuery.optString(name).equals(actualQuery.optString(name))) return false;
        }
        return true;
    }

    private JSONObject observationCheck() throws JSONException {
        JSONArray declared = new JSONArray();
        JSONArray steps = phaseSpec.getJSONArray("steps");
        Set<String> declaredSet = new LinkedHashSet<>();
        for (int index = 0; index < steps.length(); index++) {
            String id = steps.getJSONObject(index).getString("id");
            declared.put(id);
            declaredSet.add(id);
        }
        JSONArray actual = new JSONArray();
        Set<String> actualSet = new LinkedHashSet<>();
        for (int index = 0; index < observations.length(); index++) {
            String id = observations.getJSONObject(index).getString("id");
            actual.put(id);
            actualSet.add(id);
        }
        JSONArray missing = new JSONArray();
        JSONArray extra = new JSONArray();
        for (String id : declaredSet) if (!actualSet.contains(id)) missing.put(id);
        for (String id : actualSet) if (!declaredSet.contains(id)) extra.put(id);
        boolean sameOrder = declared.length() == actual.length();
        for (int index = 0; sameOrder && index < declared.length(); index++) {
            if (!declared.getString(index).equals(actual.getString(index))) sameOrder = false;
        }
        return new JSONObject()
            .put("declared", declared)
            .put("actual", actual)
            .put("missing", missing)
            .put("extra", extra)
            .put("match", missing.length() == 0 && extra.length() == 0 && sameOrder);
    }

    // ------------------------------------------------------------------ cleanup

    /**
     * Seed success retains the owned root and fences its preferences so the restart can
     * read them; a seed that failed removes what it created. A restart removes the union
     * of the preference names the seed owned and the root itself. A phase that never
     * established ownership of an existing root removes nothing and says so.
     */
    private JSONObject cleanup(boolean succeeded) throws Exception {
        JSONObject cleanup = new JSONObject();
        if (database != null) {
            try {
                call(database, "close");
                cleanup.put("databaseClosed", true);
            } catch (Throwable error) {
                cleanup.put("databaseClosed", false).put("databaseError", describe(error));
            }
            database = null;
        } else {
            cleanup.put("databaseClosed", JSONObject.NULL);
        }
        if (replay != null) {
            try {
                cleanup.put("openConnections", replay.openConnections());
                replay.close();
                cleanup.put("serverClosed", true);
            } catch (Throwable error) {
                cleanup.put("serverClosed", false).put("serverError", describe(error));
            }
            replay = null;
        } else {
            cleanup.put("serverClosed", JSONObject.NULL);
        }
        if (!scratch.isBound()) {
            cleanup.put("ownership", "none: the phase never established ownership, prior state"
                + " left intact")
                .put("scratchRoot", scratch.root.getAbsolutePath())
                .put("scratchRetained", scratch.root.exists())
                .put("scratchRemoved", false)
                .put("preferencesRemoved", new JSONArray());
            return cleanup;
        }
        boolean seed = "seed".equals(phase);
        cleanup.put("ownership",
            seed ? "created-fresh-root" : "validated-seed-owner")
            .put("scratchRoot", scratch.root.getAbsolutePath());
        if (seed && succeeded) {
            JSONArray fenced = new JSONArray();
            for (String name : scratch.ownedPreferences()) {
                fenced.put(new JSONObject().put("name", name).put("ok", scratch.fence(name)));
            }
            cleanup.put("preferencesFenced", fenced)
                .put("preferencesRemoved", new JSONArray())
                .put("scratchRetained", true)
                .put("scratchRemoved", false)
                .put("ownerFile", new File(scratch.root, OWNER_FILE).getAbsolutePath());
            scratch.writeOwnerComplete(runId);
        } else {
            JSONArray removed = new JSONArray();
            for (String name : scratch.ownedPreferences()) {
                removed.put(new JSONObject().put("name", name)
                    .put("ok", scratch.deletePreference(name)));
            }
            cleanup.put("preferencesFenced", new JSONArray())
                .put("preferencesRemoved", removed)
                .put("scratchRetained", false)
                .put("scratchRemoved", scratch.removeRoot());
        }
        return cleanup;
    }

    // -------------------------------------------------------------- reflection

    /** Runs one suspend call through {@code kotlinx.coroutines.runBlocking}. */
    private Object runSuspend(ClassLoader loader, SuspendCall call) throws Exception {
        Class<?> builders = loader.loadClass("kotlinx.coroutines.BuildersKt");
        Method runBlocking = null;
        for (Method candidate : builders.getMethods()) {
            if (!candidate.getName().equals("runBlocking") || candidate.getParameterCount() != 2) {
                continue;
            }
            if (candidate.getParameterTypes()[1].getName()
                    .equals("kotlin.jvm.functions.Function2")) {
                runBlocking = candidate;
            }
        }
        if (runBlocking == null) throw new IllegalStateException("kotlinx runBlocking absent");
        Class<?> function2 = loader.loadClass("kotlin.jvm.functions.Function2");
        Object block = Proxy.newProxyInstance(loader, new Class<?>[]{function2},
            (proxy, method, args) -> {
                switch (method.getName()) {
                    case "invoke":
                        return call.run(args[1]);
                    case "toString":
                        return "state-session-oracle-block";
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
    private static Object call(Class<?> owner, Object instance, String name, int parameterCount,
            Object[] arguments, Object continuation) throws Throwable {
        Method target = null;
        for (Method candidate : owner.getMethods()) {
            // A suspend function whose return type is an inline value class is name
            // mangled with a hash suffix (kotlin.Result -> getChapterListAwait-BWLJW6A),
            // so the base name is matched as a prefix.
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
        if (target == null) throw new IllegalStateException("frozen suspend entry absent: " + name);
        Object[] full = new Object[parameterCount];
        System.arraycopy(arguments, 0, full, 0, arguments.length);
        full[parameterCount - 1] = continuation;
        try {
            return target.invoke(instance, full);
        } catch (InvocationTargetException error) {
            throw error.getCause();
        }
    }

    /** The value inside a {@code kotlin.Result}; a failure surfaces the frozen exception. */
    private static List<?> unwrapResult(Object result) throws Exception {
        if (result instanceof List) return (List<?>) result;
        if (result == null) throw new IllegalStateException("table of contents returned null");
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
            for (java.lang.reflect.Field field : payload.getClass().getDeclaredFields()) {
                if (!field.getName().equals("exception")) continue;
                field.setAccessible(true);
                Object exception = field.get(payload);
                if (exception instanceof Exception) throw (Exception) exception;
                if (exception instanceof Throwable) {
                    throw new IllegalStateException((Throwable) exception);
                }
            }
        }
        throw new IllegalStateException("table of contents result is "
            + result.getClass().getName() + " payload=" + payload);
    }

    private static Object call(Object target, String name, Object... args) throws Exception {
        for (Method method : target.getClass().getMethods()) {
            if (!method.getName().equals(name)
                    || method.getParameterTypes().length != args.length) {
                continue;
            }
            boolean matches = true;
            Class<?>[] types = method.getParameterTypes();
            for (int index = 0; index < types.length; index++) {
                if (args[index] != null && !types[index].isPrimitive()
                        && !types[index].isInstance(args[index])) {
                    matches = false;
                }
            }
            if (matches) {
                try {
                    return method.invoke(target, args);
                } catch (InvocationTargetException error) {
                    Throwable cause = error.getCause();
                    if (cause instanceof Exception) throw (Exception) cause;
                    throw new IllegalStateException(cause);
                }
            }
        }
        throw new NoSuchMethodException(target.getClass().getName() + "." + name);
    }

    private static String str(Class<?> owner, Object instance, String getter) {
        Object value = invokeGetter(owner, instance, getter);
        return value == null ? "" : value.toString();
    }

    private static Object invokeGetter(Class<?> owner, Object instance, String getter) {
        try {
            return owner.getMethod(getter).invoke(instance);
        } catch (Exception error) {
            throw new IllegalStateException("frozen getter absent: " + getter, error);
        }
    }

    // ------------------------------------------------------------------ helpers

    private byte[] readAsset(String name) throws IOException {
        try (InputStream input = getContext().getAssets().open(name)) {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int read;
            while ((read = input.read(chunk)) > 0) buffer.write(chunk, 0, read);
            return buffer.toByteArray();
        }
    }

    /** CRLF normalisation, so a Windows checkout pins the same corpus bytes as the blob. */
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

    private interface SuspendCall {
        Object run(Object continuation) throws Throwable;
    }

    /**
     * The corpus' replay server: every response comes from the corpus, an undeclared
     * request is answered 404 and recorded, and the port is the one the corpus names.
     *
     * <p>A response is either common to both phases or scoped to one; the active set is
     * common plus the current phase, with no precedence between them. Two active
     * responses for the same selector (method, path and declared query) are a refusal,
     * because which one answered would otherwise be undecidable. Matching a request
     * follows {@code SliceOracle}'s rule: a declared query must match exactly and wins
     * over a response that declares none.
     */
    private static final class StateReplay {
        private final JSONArray active;
        private final JSONArray requests;
        private final JSONArray unmatched;
        private final JSONArray serverErrors;
        private final JSONArray stageTrace;
        private final AtomicReference<String> stage;
        private final String origin;
        private final int port;
        private final ExecutorService clients = Executors.newFixedThreadPool(4);
        private final Set<Socket> openSockets = new java.util.HashSet<>();
        private ServerSocket server;
        private Thread worker;
        private final java.util.concurrent.atomic.AtomicInteger open =
            new java.util.concurrent.atomic.AtomicInteger();

        StateReplay(JSONObject corpus, String phase, JSONArray requests, JSONArray unmatched,
                JSONArray serverErrors, JSONArray stageTrace, AtomicReference<String> stage)
                throws Exception {
            this.requests = requests;
            this.unmatched = unmatched;
            this.serverErrors = serverErrors;
            this.stageTrace = stageTrace;
            this.stage = stage;
            this.origin = corpus.getString("origin");
            URL url = new URL(origin);
            this.port = url.getPort() > 0 ? url.getPort() : 80;
            this.active = new JSONArray();
            JSONArray declared = corpus.getJSONArray("responses");
            Map<String, String> selectors = new LinkedHashMap<>();
            for (int index = 0; index < declared.length(); index++) {
                JSONObject response = declared.getJSONObject(index);
                String scoped = response.optString("phase", "");
                if (!scoped.isEmpty() && !scoped.equals(phase)) continue;
                String selector = selectorOf(response);
                if (selectors.containsKey(selector)) {
                    throw new IllegalStateException("two active responses select " + selector
                        + ": " + selectors.get(selector) + " and " + response.getString("id"));
                }
                selectors.put(selector, response.getString("id"));
                active.put(response);
            }
        }

        private static String selectorOf(JSONObject response) throws JSONException {
            JSONObject query = response.optJSONObject("query");
            String selector = response.optString("method") + " " + response.optString("path");
            if (query == null) return selector;
            StringBuilder text = new StringBuilder(selector).append(" ?");
            Set<String> names = new TreeSet<>();
            Iterator<String> keys = query.keys();
            while (keys.hasNext()) names.add(keys.next());
            for (String name : names) {
                text.append(name).append('=').append(query.optString(name)).append('&');
            }
            return text.toString();
        }

        String origin() {
            return origin;
        }

        void start() throws IOException {
            server = new ServerSocket(port, 16, InetAddress.getByName("127.0.0.1"));
            worker = new Thread(this::accept, "state-session-replay");
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
                    String headerName = line.substring(0, separator).trim().toLowerCase(Locale.US);
                    String value = line.substring(separator + 1).trim();
                    String existing = headers.get(headerName);
                    headers.put(headerName, existing == null ? value : existing + ", " + value);
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
                    byte[] bytes = declared.optString("body", "")
                        .getBytes(StandardCharsets.UTF_8);
                    StringBuilder head = new StringBuilder();
                    head.append("HTTP/1.1 ").append(declared.optInt("status", 200))
                        .append(" OK\r\n");
                    JSONObject declaredHeaders = declared.optJSONObject("headers");
                    if (declaredHeaders != null) {
                        Iterator<String> names = declaredHeaders.keys();
                        while (names.hasNext()) {
                            String headerName = names.next();
                            head.append(headerName).append(": ")
                                .append(declaredHeaders.optString(headerName)).append("\r\n");
                        }
                    }
                    head.append("Content-Length: ").append(bytes.length).append("\r\n\r\n");
                    output.write(head.toString().getBytes(StandardCharsets.US_ASCII));
                    output.write(bytes);
                }
                output.flush();
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
            for (int index = 0; index < active.length(); index++) {
                JSONObject response = active.optJSONObject(index);
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
            for (JSONObject candidate : candidates) {
                if (candidate.isNull("query")) return candidate;
            }
            return null;
        }
    }

    /**
     * Storage-only wrapper. The frozen code, its assets and resources stay intact; only
     * the files, database and preference locations move into a task-owned root plus a
     * task-owned preference name prefix.
     *
     * <p>Nothing touches the disk until the phase is bound, because the phase decides
     * whether this invocation may create the root (seed) or has to validate the manifest
     * the seed left behind (restart). A restart may only reuse the preference namespaces
     * the seed recorded; the seed requires each namespace it meets to be empty.
     */
    private static final class ScratchContext extends ContextWrapper {
        final File root;
        private final boolean rootExistedAtStart;
        private String phase;
        private boolean bound;
        private boolean probing;
        private final Set<String> preferences = new LinkedHashSet<>();
        private final Set<String> pendingBeforeBind = new LinkedHashSet<>();
        private Set<String> ownedFromOwner = new LinkedHashSet<>();
        private JSONObject owner;

        ScratchContext(Context base) {
            super(base);
            root = new File(base.getCacheDir(), SCRATCH_ROOT_NAME);
            rootExistedAtStart = root.exists();
        }

        boolean isBound() {
            return bound;
        }

        boolean rootExistedAtStart() {
            return rootExistedAtStart;
        }

        void bind(String requestedPhase, JSONObject identity) throws Exception {
            if ("seed".equals(requestedPhase)) {
                // A seed needs a fresh root. Anything that is already there is left alone
                // for inspection, never deleted and never reused.
                if (rootExistedAtStart || root.exists()) {
                    throw new IllegalStateException("scratch root already exists; a seed needs a"
                        + " fresh one and a restart needs its owner manifest, inspect first: "
                        + root);
                }
                // A preference namespace the phase read before it was bound (no frozen code
                // runs that early; the check is here so it cannot pass unnoticed) has to be
                // empty too.
                for (String name : pendingBeforeBind) {
                    if (!getBaseContext().getSharedPreferences(name, 0).getAll().isEmpty()) {
                        throw new IllegalStateException(
                            "seed preference namespace is not fresh: " + name);
                    }
                }
                if (!root.mkdirs()) {
                    throw new IllegalStateException("cannot create scratch root " + root);
                }
                preferences.addAll(pendingBeforeBind);
                owner = new JSONObject()
                    .put("fixtureId", identity.getString("fixtureId"))
                    .put("corpusVersion", identity.getInt("corpusVersion"))
                    .put("corpusSha256Lf", identity.getString("corpusSha256Lf"))
                    .put("targetPackage", identity.getString("targetPackage"))
                    .put("targetApkSha256", identity.getString("targetApkSha256"))
                    .put("harnessPackage", identity.getString("harnessPackage"))
                    .put("harnessApkSha256", identity.getString("harnessApkSha256"))
                    .put("preferences", recordedPreferences())
                    .put("createdAt", System.currentTimeMillis());
                phase = "seed";
                bound = true;
                writeOwner();
                return;
            }
            if (!"restart".equals(requestedPhase)) {
                throw new IllegalStateException("phase must be seed or restart, got "
                    + requestedPhase);
            }
            File ownerFile = new File(root, OWNER_FILE);
            if (!root.isDirectory() || !ownerFile.isFile()) {
                throw new IllegalStateException("a restart needs the seed's owned scratch root"
                    + " and its owner manifest; leaving what is there untouched: " + ownerFile);
            }
            JSONObject declared = new JSONObject(
                new String(readFile(ownerFile), StandardCharsets.UTF_8));
            requireOwner(declared, identity);
            if (!declared.optBoolean("complete", false)) {
                throw new IllegalStateException("the seed that owns " + root
                    + " did not complete; refusing to reuse it");
            }
            JSONArray names = declared.optJSONArray("preferences");
            Set<String> owned = new LinkedHashSet<>();
            if (names != null) {
                for (int index = 0; index < names.length(); index++) {
                    owned.add(names.getString(index));
                }
            }
            for (String name : pendingBeforeBind) {
                if (!owned.contains(name)) {
                    throw new IllegalStateException("restart asked for a preference namespace"
                        + " the seed did not own: " + name);
                }
            }
            ownedFromOwner = owned;
            owner = declared;
            phase = "restart";
            bound = true;
        }

        private static void requireOwner(JSONObject declared, JSONObject identity)
                throws JSONException {
            for (String field : new String[]{"fixtureId", "corpusSha256Lf", "targetPackage",
                    "targetApkSha256", "harnessPackage", "harnessApkSha256"}) {
                String expected = identity.getString(field);
                String actual = declared.optString(field, "");
                if (!expected.equals(actual)) {
                    throw new IllegalStateException("the retained scratch belongs to another"
                        + " run: owner " + field + "=" + actual + ", this run " + expected);
                }
            }
            if (declared.optInt("corpusVersion", -1) != identity.getInt("corpusVersion")) {
                throw new IllegalStateException("the retained scratch has another corpusVersion");
            }
        }

        private void writeOwner() throws Exception {
            // Only the seed owns the manifest. A restart validates and reuses it, and
            // never rewrites it.
            if (owner == null || !"seed".equals(phase)) return;
            byte[] bytes = owner.toString(2).getBytes(StandardCharsets.UTF_8);
            File target = new File(root, OWNER_FILE);
            File temporary = new File(root, OWNER_FILE + ".tmp");
            try (FileOutputStream stream = new FileOutputStream(temporary)) {
                stream.write(bytes);
                stream.getFD().sync();
            }
            if (!temporary.renameTo(target)) {
                throw new IllegalStateException("cannot publish the owner manifest " + target);
            }
        }

        void writeOwnerComplete(String seedRunId) throws Exception {
            if (owner == null) return;
            owner.put("seedRunId", seedRunId)
                .put("seedPid", android.os.Process.myPid())
                .put("complete", true)
                .put("completedAt", System.currentTimeMillis())
                .put("preferences", recordedPreferences());
            writeOwner();
        }

        Set<String> ownedPreferences() {
            Set<String> names = new LinkedHashSet<>(preferences);
            names.addAll(ownedFromOwner);
            return names;
        }

        private JSONArray recordedPreferences() {
            JSONArray names = new JSONArray();
            for (String name : preferences) names.put(name);
            return names;
        }

        /**
         * A directory under the owned root. Before the phase is bound only the path is
         * handed out: the frozen application's start-up providers may ask for one, and
         * creating it then would touch a root this invocation has not established
         * ownership of yet.
         */
        private File directory(String name) {
            File file = new File(root, name);
            if (bound && !file.isDirectory() && !file.mkdirs()) {
                throw new IllegalStateException("cannot create scratch directory " + file);
            }
            return file;
        }

        private void requireBound() {
            if (!bound) {
                throw new IllegalStateException(
                    "storage was reached before the phase bound the scratch root");
            }
        }

        @Override
        public File getFilesDir() {
            return directory("files");
        }

        @Override
        public File getCacheDir() {
            return directory("cache");
        }

        @Override
        public File getNoBackupFilesDir() {
            return directory("no-backup");
        }

        @Override
        public File getCodeCacheDir() {
            return directory("code-cache");
        }

        @Override
        public File getDir(String name, int mode) {
            return directory("dir-" + name);
        }

        @Override
        public File getExternalFilesDir(String type) {
            return directory("external-" + (type == null ? "files" : type));
        }

        @Override
        public File[] getExternalFilesDirs(String type) {
            return new File[]{getExternalFilesDir(type)};
        }

        @Override
        public File getExternalCacheDir() {
            return directory("external-cache");
        }

        @Override
        public File[] getExternalCacheDirs() {
            return new File[]{getExternalCacheDir()};
        }

        @Override
        public File getDatabasePath(String name) {
            return new File(directory("databases"), name);
        }

        @Override
        public SQLiteDatabase openOrCreateDatabase(String name, int mode,
                SQLiteDatabase.CursorFactory factory) {
            return openOrCreateDatabase(name, mode, factory, null);
        }

        @Override
        public SQLiteDatabase openOrCreateDatabase(String name, int mode,
                SQLiteDatabase.CursorFactory factory, DatabaseErrorHandler handler) {
            requireBound();
            return SQLiteDatabase.openDatabase(getDatabasePath(name).getPath(), factory,
                SQLiteDatabase.CREATE_IF_NECESSARY | SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING,
                handler);
        }

        @Override
        public boolean deleteDatabase(String name) {
            return SQLiteDatabase.deleteDatabase(getDatabasePath(name));
        }

        @Override
        public SharedPreferences getSharedPreferences(String name, int mode) {
            String scoped = PREFERENCE_PREFIX + name;
            if (!bound) {
                // No ownership yet: the name is delegated under the task prefix and
                // remembered, so the bind check can refuse a non-fresh (seed) or an
                // unowned (restart) namespace instead of silently using it.
                pendingBeforeBind.add(scoped);
                return getBaseContext().getSharedPreferences(scoped, mode);
            }
            if (probing) {
                preferences.add(scoped);
                return getBaseContext().getSharedPreferences(scoped, mode);
            }
            if ("restart".equals(phase)) {
                if (!ownedFromOwner.contains(scoped)) {
                    throw new IllegalStateException("restart asked for a preference namespace"
                        + " the seed did not own: " + scoped);
                }
            } else {
                if (!preferences.contains(scoped)
                        && !getBaseContext().getSharedPreferences(scoped, mode).getAll().isEmpty()) {
                    throw new IllegalStateException(
                        "seed preference namespace is not fresh: " + scoped);
                }
                if (preferences.add(scoped)) {
                    try {
                        owner.put("preferences", recordedPreferences());
                        writeOwner();
                    } catch (Exception error) {
                        throw new IllegalStateException("cannot record the owned preference "
                            + scoped, error);
                    }
                }
            }
            return getBaseContext().getSharedPreferences(scoped, mode);
        }

        /** Flushes any buffered apply() write so the retained file holds the final value. */
        boolean fence(String name) {
            return getBaseContext().getSharedPreferences(name, 0).edit().commit();
        }

        boolean deletePreference(String name) {
            boolean cleared = getBaseContext().getSharedPreferences(name, 0).edit().clear().commit();
            return getBaseContext().deleteSharedPreferences(name) && cleared;
        }

        /**
         * Proves that the frozen application's preference storage is the scratch one: the
         * requested name is registered under the task prefix, its file appears there, and
         * the installation's own file for that name never appears. The probe namespace is
         * deleted again so it leaves nothing behind, and it is never part of the owned set
         * the restart cleans up.
         */
        JSONObject probePreferences(Context app, File dataDir, String probe) throws Exception {
            String scoped = PREFERENCE_PREFIX + probe;
            boolean installationFile = new File(dataDir, probe + ".xml").exists();
            boolean registered;
            boolean scopedFile;
            probing = true;
            try {
                SharedPreferences prefs = app.getSharedPreferences(probe, 0);
                registered = preferences.contains(scoped);
                prefs.edit().putString("probe", "1").commit();
                scopedFile = new File(dataDir, scoped + ".xml").exists();
            } finally {
                probing = false;
            }
            deletePreference(scoped);
            if (preferences.remove(scoped)) writeOwner();
            return new JSONObject()
                .put("name", scoped)
                .put("installationFile", installationFile)
                .put("scopedRegistered", registered)
                .put("scopedFile", scopedFile);
        }

        boolean removeRoot() {
            return remove(root);
        }

        private static boolean remove(File file) {
            File[] children = file.listFiles();
            boolean ok = true;
            if (children != null) for (File child : children) ok &= remove(child);
            return file.delete() && ok;
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
}
