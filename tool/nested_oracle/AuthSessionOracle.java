package io.liber.oracle.nested;

import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.webkit.CookieManager;
import android.webkit.WebView;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
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
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The frozen side of the AUTH-SESSION-01 corpus: drives the installed,
 * hash-pinned {@code io.legado.app.debug} ordinary source login, loginCheckJs,
 * header and CookieStore/CookieManager APIs plus WebBook's four suspend stage
 * entry points, against the corpus' own two loopback replay listeners.
 *
 * <p>The two phases are two process lifetimes. {@code seed} creates a fresh
 * task-owned scratch root, records the login/header/cookie lifecycle, closes the
 * database and both listeners and retains the root. {@code restart} requires the
 * seed's owner manifest, reads the persisted cookie state before any request,
 * observes the same effective requests, and removes the root and owned
 * preferences.
 *
 * <p>The harness reuses {@code StateSessionOracle.ScratchContext} for storage
 * containment and ships {@code tool/auth_session/fixtures.json} as its asset.
 * No Legado class is rebuilt and no row is written directly.
 */
public final class AuthSessionOracle extends Instrumentation {

    private static final String ASSET = "auth-session-fixtures.json";
    private static final String STREAM_KEY = "AUTH_SESSION_ORACLE_BASE64";
    private static final String SCRATCH_ROOT_NAME = "liber-auth-session-01";
    private static final String PREFERENCE_PREFIX = "liber_auth_session_01_";
    private static final String WEBVIEW_SUFFIX = "liber-auth-session-01";
    private static final String OWNER_FILE = "owner.json";

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
    private String phase;
    private String runId;
    private JSONObject corpus;
    private JSONObject phaseSpec;
    private AuthReplay replay;
    private Object database;
    private ClassLoader loader;
    private JSONObject requestCheckValue;
    private JSONObject observationCheckValue;
    private JSONObject webViewReceipt;
    private String webViewSuffixFailure;
    private String webViewPreflightFailure;
    private boolean cleanupOk;

    @Override
    public Application newApplication(ClassLoader cl, String name, Context context)
            throws InstantiationException, IllegalAccessException, ClassNotFoundException {
        scratch = new StateSessionOracle.ScratchContext(context, SCRATCH_ROOT_NAME,
            PREFERENCE_PREFIX);
        // This is the earliest process point available to instrumentation: before
        // LoadedApk finishes makeApplication, before any ContentProvider and before the
        // frozen Application.onCreate. The API only stores a pre-init suffix; it does not
        // initialize WebView or touch storage. Any prior provider initialization is a
        // refusal, never a fallback to the default profile.
        if (Build.VERSION.SDK_INT < 28) {
            webViewSuffixFailure = "WebView.setDataDirectorySuffix needs SDK 28, device is "
                + Build.VERSION.SDK_INT;
        } else {
            try {
                WebView.setDataDirectorySuffix(WEBVIEW_SUFFIX);
            } catch (Throwable error) {
                webViewSuffixFailure = describe(error);
            }
        }
        return super.newApplication(cl, Application.class.getName(), scratch);
    }

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        if (args != null) phase = args.getString("phase");
        log("onCreate phase=" + phase);
        new Handler(Looper.getMainLooper()).post(() -> {
            log("main looper reached; starting the worker thread");
            new Thread(this::run, "auth-session-oracle").start();
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
                String where = stage.get();
                log("watchdog: no result after 240s; stage=" + where);
                Bundle status = new Bundle();
                status.putString("stream", STREAM_KEY + "=" + base64(timeoutReport(where))
                    + "\nAuth session oracle " + phase + ": timed out in stage " + where
                    + " after " + requests.length() + " requests\n");
                finish(1, status);
            }
        }, "auth-session-watchdog");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    private void log(String message) {
        Log.i("AuthSessionOracle", message);
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
            validateCorpus();
            phaseSpec = corpus.getJSONObject("phases").getJSONObject(phase);
            log("corpus " + corpus.getString("fixtureId") + " phase " + phase);

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

            scratch.bind(phase, identity);
            report.put("isolation", checkIsolation());
            log("isolation ok");
            database = loader.loadClass("io.legado.app.data.AppDatabaseKt")
                .getMethod("getAppDb").invoke(null);

            replay = new AuthReplay(corpus, phase, requests, unmatched, serverErrors,
                stageTrace, stage);
            replay.start();
            log("replay listeners bound: " + replay.endpoints());

            drive();
            requestCheckValue = requestCheck();
            observationCheckValue = observationCheck();
            if (!requestCheckValue.getBoolean("match")) {
                throw new IllegalStateException("actual request trace does not match the"
                    + " corpus: " + requestCheckValue);
            }
            if (!observationCheckValue.getBoolean("match")) {
                throw new IllegalStateException("actual observation ids do not match the"
                    + " corpus: " + observationCheckValue);
            }
            ok = true;
        } catch (Throwable error) {
            failure = describe(error);
            if (scratch != null) scratch.refuseWaiters(failure);
            log("phase " + phase + " failed in stage " + stage.get() + ": " + failure);
        } finally {
            stage.set("cleanup");
            try {
                cleanup = cleanup(ok);
                if (!cleanupOk && failure == null) {
                    failure = "cleanup: " + cleanup.optString("cleanupFailure",
                        "the phase's cleanup did not verify");
                }
                ok = ok && cleanupOk;
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
                report.put("stageTrace", snapshot(stageTrace))
                    .put("requests", snapshot(requests))
                    .put("unmatchedRequests", snapshot(unmatched))
                    .put("serverErrors", snapshot(serverErrors))
                    .put("requestCheck", requestCheckValue != null
                        ? requestCheckValue : requestCheck())
                    .put("observations", snapshot(observations))
                    .put("observationCheck", observationCheckValue != null
                        ? observationCheckValue : observationCheck())
                    .put("inventory", inventory)
                    .put("webView", webViewReport())
                    .put("cleanup", cleanup)
                    .put("analysisFailure", failure == null ? JSONObject.NULL : failure);
            } catch (Throwable error) {
                ok = false;
                failure = (failure == null ? "" : failure + " | ")
                    + "report assembly: " + describe(error);
                log("report assembly failed: " + describe(error));
            }
            status.putString("stream", STREAM_KEY + "=" + base64(report.toString())
                + "\nAuth session oracle " + phase + ": "
                + (failure == null ? "recorded " + requests.length() + " requests, "
                    + observations.length() + " observations" : "failed: " + failure) + "\n");
            log("report assembled; failure=" + failure);
            finished.set(true);
            finish(ok ? -1 : 1, status);
        }
    }

    // ---------------------------------------------------------------- identity

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
            throw new IllegalStateException("the storage-only application is device-protected;"
                + " WebView could replace it with a credential-protected context");
        }
        if (!app.getFilesDir().equals(scratch.getFilesDir())) {
            throw new IllegalStateException("appCtx escaped the scratch files directory: "
                + app.getFilesDir());
        }
        if (!app.getDatabasePath("legado.db").equals(scratch.getDatabasePath("legado.db"))) {
            throw new IllegalStateException("appCtx escaped the scratch database directory: "
                + app.getDatabasePath("legado.db"));
        }
        File dataDir = new File(getTargetContext().getApplicationInfo().dataDir, "shared_prefs");
        JSONObject probe = "seed".equals(phase)
            ? scratch.seedProbePreferences(app, dataDir, "liber_auth_session_probe")
            : scratch.restartProbePreferences(dataDir, "liber_auth_session_probe");
        if (probe.getBoolean("installationFile")
                || !probe.getBoolean("registered")
                || !probe.getBoolean("scopedFile")) {
            throw new IllegalStateException("appCtx preference storage is not scratch-scoped: "
                + probe);
        }
        if ("seed".equals(phase) && !probe.getBoolean("committed")) {
            throw new IllegalStateException("the seed probe preference did not commit: " + probe);
        }
        JSONObject webViewPaths = webViewPathPrecheck(app);
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
            .put("scratchCreatedByThisRun", "seed".equals(phase))
            .put("scratchRetainedFromSeed", "restart".equals(phase))
            .put("deviceProtected", app.isDeviceProtectedStorage())
            .put("webViewPathPrecheck", webViewPaths)
            .put("frozenAppOnCreate",
                "not-run: newApplication returns a storage-only android.app.Application, so"
                    + " io.legado.app.App.onCreate (crash handler, file logging, cronet"
                    + " pre-download, DefaultData.upVersion, freeze monitor, LiveEventBus,"
                    + " URL factory) does not run; the splitties AppCtxInitProvider does run"
                    + " and is what this check measures");
    }

    /**
     * The suffix changes the provider's getDir/cache names. Before any provider call,
     * prove those names resolve inside the already-bound AUTH root. This is the source
     * mapping precheck; the actual provider PathUtils values are measured again after
     * initialization and must agree before the first CookieStore.removeCookie.
     */
    private JSONObject webViewPathPrecheck(Context app) throws Exception {
        File data = app.getDir("webview_" + WEBVIEW_SUFFIX, Context.MODE_PRIVATE);
        File cache = new File(app.getCacheDir(), "webview_" + WEBVIEW_SUFFIX);
        File textures = app.getDir("textures", Context.MODE_PRIVATE);
        requireInside("WebView data precheck", data);
        requireInside("WebView cache precheck", cache);
        requireInside("WebView textures precheck", textures);
        return new JSONObject()
            .put("data", data.getCanonicalPath())
            .put("cache", cache.getCanonicalPath())
            .put("textures", textures.getCanonicalPath())
            .put("insideRoot", true);
    }

    // ---------------------------------------------------------------- drive

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
                case "login":
                    stepLogin(step, sources);
                    break;
                case "headerMap":
                    stepHeaderMap(step, sources);
                    break;
                case "stage":
                    stepStage(step, sources, books, chapters);
                    break;
                case "cookieState":
                    stepCookieState(step, sources);
                    break;
                case "cookieKeyRemoval":
                    stepCookieKeyRemoval(step, sources);
                    break;
                case "removeLoginHeader":
                    stepRemoveLoginHeader(step, sources);
                    break;
                case "loginHeaderPut":
                    stepLoginHeaderPut(step, sources);
                    break;
                case "state":
                    stepState(step, sources);
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
            if (entry.has("jsLib")) sourceJson.put("jsLib", entry.getString("jsLib"));
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

    private void stepLogin(JSONObject step, Map<String, Object> sources) throws Exception {
        Object source = require(sources, step.getString("source"), "source");
        String infoJson = step.getString("loginInfo");
        JSONArray ui = loginUi(source);
        Object put = call(source, "putLoginInfo", infoJson);
        Object info = call(source, "getLoginInfoMap");
        call(source, "login");
        Object probe = call(source, "get", step.getString("probeKey"));
        JSONObject value = new JSONObject()
            .put("kind", "login")
            .put("source", step.getString("source"))
            .put("loginUi", ui)
            .put("putLoginInfo", put == null ? JSONObject.NULL : put)
            .put("loginInfo", jsonMap((Map<?, ?>) info))
            .put("loginOutcome", probe == null ? "" : probe.toString())
            .put("loginHeader", nullToNull(call(source, "getLoginHeader")))
            .put("loginHeaderMap", jsonMapOrNull((Map<?, ?>) call(source, "getLoginHeaderMap")));
        observe(step.getString("id"), value);
    }

    private void stepHeaderMap(JSONObject step, Map<String, Object> sources) throws Exception {
        Object source = require(sources, step.getString("source"), "source");
        JSONObject value = new JSONObject()
            .put("kind", "headerMap")
            .put("source", step.getString("source"))
            .put("noLogin", jsonMap((Map<?, ?>) call(source, "getHeaderMap", Boolean.FALSE)))
            .put("withLogin", jsonMap((Map<?, ?>) call(source, "getHeaderMap", Boolean.TRUE)))
            .put("loginHeader", nullToNull(call(source, "getLoginHeader")))
            .put("loginHeaderMap", jsonMapOrNull((Map<?, ?>) call(source, "getLoginHeaderMap")));
        observe(step.getString("id"), value);
    }

    private void stepStage(JSONObject step, Map<String, Object> sources,
            Map<String, Object> books, Map<String, Map<String, Object>> chapters)
            throws Throwable {
        String sourceId = step.getString("source");
        Object source = require(sources, sourceId, "source");
        String stageKind = step.getString("stage");
        JSONObject value = new JSONObject()
            .put("kind", "stage")
            .put("stage", stageKind)
            .put("source", sourceId);
        switch (stageKind) {
            case "search":
                stepSearch(step, source, books, value);
                break;
            case "details":
                stepDetails(step, source, books, value);
                break;
            case "toc":
                stepToc(step, source, books, chapters, value);
                break;
            case "content":
                stepContent(step, source, books, chapters, value);
                break;
            default:
                throw new IllegalStateException("unknown stage " + stageKind);
        }
        value.put("check", checkValue(source, step.getString("checkKey")));
        observe(step.getString("id"), value);
    }

    private void stepSearch(JSONObject step, Object source, Map<String, Object> books,
            JSONObject value) throws Throwable {
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        Class<?> searchBookClass = loader.loadClass("io.legado.app.data.entities.SearchBook");
        Class<?> bookClass = loader.loadClass("io.legado.app.data.entities.Book");
        String keyword = step.getString("keyword");
        Object result = runSuspend(loader, continuation -> call(webBookClass, webBook,
            "searchBookAwait", 6,
            new Object[]{source, keyword, Integer.valueOf(1), null, null}, continuation));
        if (!(result instanceof List)) throw new IllegalStateException("search returned " + result);
        List<?> results = (List<?>) result;
        JSONArray declared = step.getJSONArray("books");
        if (results.size() != declared.length()) {
            throw new IllegalStateException("search returned " + results.size()
                + " results, corpus declares " + declared.length());
        }
        JSONArray observed = new JSONArray();
        for (int index = 0; index < declared.length(); index++) {
            String bookId = declared.getString(index);
            JSONObject declaredBook = declaredBook(bookId);
            Object item = results.get(index);
            Object book = searchBookClass.getMethod("toBook").invoke(item);
            String bookUrl = str(bookClass, book, "getBookUrl");
            if (!bookUrl.equals(declaredBook.getString("bookUrl"))) {
                throw new IllegalStateException("search result " + bookId + " is " + bookUrl
                    + ", corpus declares " + declaredBook.getString("bookUrl"));
            }
            observed.put(new JSONObject()
                .put("id", bookId)
                .put("name", str(searchBookClass, item, "getName"))
                .put("author", str(searchBookClass, item, "getAuthor"))
                .put("kind", str(searchBookClass, item, "getKind"))
                .put("bookUrl", str(searchBookClass, item, "getBookUrl")));
            books.put(bookId, book);
        }
        value.put("results", observed);
    }

    private void stepDetails(JSONObject step, Object source, Map<String, Object> books,
            JSONObject value) throws Throwable {
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        Class<?> bookClass = loader.loadClass("io.legado.app.data.entities.Book");
        String bookId = step.getString("book");
        Object book = require(books, bookId, "book");
        runSuspend(loader, continuation -> call(webBookClass, webBook, "getBookInfoAwait", 4,
            new Object[]{source, book, Boolean.TRUE}, continuation));
        value.put("book", bookId)
            .put("bookUrl", str(bookClass, book, "getBookUrl"))
            .put("name", str(bookClass, book, "getName"))
            .put("author", str(bookClass, book, "getAuthor"))
            .put("intro", str(bookClass, book, "getIntro"))
            .put("latestChapterTitle", str(bookClass, book, "getLatestChapterTitle"))
            .put("tocUrl", str(bookClass, book, "getTocUrl"));
    }

    private void stepToc(JSONObject step, Object source, Map<String, Object> books,
            Map<String, Map<String, Object>> chapters, JSONObject value) throws Throwable {
        Class<?> webBookClass = loader.loadClass("io.legado.app.model.webBook.WebBook");
        Object webBook = webBookClass.getField("INSTANCE").get(null);
        Class<?> chapterClass = loader.loadClass("io.legado.app.data.entities.BookChapter");
        String bookId = step.getString("book");
        Object book = require(books, bookId, "book");
        Object result = runSuspend(loader, continuation -> call(webBookClass, webBook,
            "getChapterListAwait", 4, new Object[]{source, book, Boolean.FALSE}, continuation));
        List<?> list = unwrapResult(result);
        if (list.isEmpty()) throw new IllegalStateException("table of contents is empty");
        JSONArray observed = new JSONArray();
        Map<String, Object> byUrl = new LinkedHashMap<>();
        for (Object chapter : list) {
            String url = str(chapterClass, chapter, "getUrl");
            byUrl.put(url, chapter);
            observed.put(new JSONObject()
                .put("url", url)
                .put("title", str(chapterClass, chapter, "getTitle"))
                .put("tag", str(chapterClass, chapter, "getTag")));
        }
        chapters.put(bookId, byUrl);
        value.put("book", bookId).put("chapters", observed);
    }

    private void stepContent(JSONObject step, Object source, Map<String, Object> books,
            Map<String, Map<String, Object>> chapters, JSONObject value) throws Throwable {
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
        Object text = runSuspend(loader, continuation -> call(webBookClass, webBook,
            "getContentAwait", 6,
            new Object[]{source, book, chapter, null, Boolean.FALSE}, continuation));
        value.put("book", bookId)
            .put("chapter", chapterUrl)
            .put("text", text == null ? "" : text.toString());
    }

    private void stepCookieState(JSONObject step, Map<String, Object> sources) throws Exception {
        JSONObject value = new JSONObject().put("kind", "cookieState");
        JSONArray ids = step.getJSONArray("sources");
        for (int index = 0; index < ids.length(); index++) {
            String id = ids.getString(index);
            Object source = require(sources, id, "source");
            value.put(id, cookieProbe(source));
        }
        observe(step.getString("id"), value);
    }

    private void stepCookieKeyRemoval(JSONObject step, Map<String, Object> sources)
            throws Exception {
        String id = step.getString("source");
        Object source = require(sources, id, "source");
        JSONObject before = cookieProbe(source);
        Object manager = cookieManager();
        JSONArray keys = step.getJSONArray("keys");
        for (int index = 0; index < keys.length(); index++) {
            call(manager, "removeCookie", sourceUrl(id), keys.getString(index));
        }
        JSONObject after = cookieProbe(source);
        observe(step.getString("id"), new JSONObject()
            .put("kind", "cookieKeyRemoval")
            .put("source", id)
            .put("removed", keys)
            .put("before", before)
            .put("after", after));
    }

    private void stepRemoveLoginHeader(JSONObject step, Map<String, Object> sources)
            throws Exception {
        String id = step.getString("source");
        Object source = require(sources, id, "source");
        JSONObject before = cookieProbe(source);
        JSONObject webView;
        try {
            webView = webViewPreflight();
        } catch (Throwable error) {
            webViewPreflightFailure = describe(error);
            throw error;
        }
        call(source, "removeLoginHeader");
        JSONObject after = cookieProbe(source);
        observe(step.getString("id"), new JSONObject()
            .put("kind", "removeLoginHeader")
            .put("source", id)
            .put("before", before)
            .put("after", after)
            .put("webViewInitialized", true));
        log("removeLoginHeader " + id + " provider=" + webView.optJSONObject("provider"));
    }

    private void stepLoginHeaderPut(JSONObject step, Map<String, Object> sources)
            throws Exception {
        String id = step.getString("source");
        Object source = require(sources, id, "source");
        JSONObject before = cookieProbe(source);
        call(source, "putLoginHeader", step.getString("header"));
        JSONObject after = cookieProbe(source);
        observe(step.getString("id"), new JSONObject()
            .put("kind", "loginHeaderPut")
            .put("source", id)
            .put("before", before)
            .put("after", after)
            .put("withLogin", jsonMap((Map<?, ?>) call(source, "getHeaderMap",
                Boolean.TRUE))));
    }

    private void stepState(JSONObject step, Map<String, Object> sources) throws Exception {
        JSONObject sessions = new JSONObject();
        JSONObject loginHeaders = new JSONObject();
        JSONObject loginInfo = new JSONObject();
        JSONObject cookies = new JSONObject();
        JSONArray ids = step.getJSONArray("sources");
        for (int index = 0; index < ids.length(); index++) {
            String id = ids.getString(index);
            Object source = require(sources, id, "source");
            sessions.put(id, nullToNull(call(cookieManager(), "getSessionCookie",
                sourceDomain(id))));
            loginHeaders.put(id, nullToNull(call(source, "getLoginHeader")));
            loginInfo.put(id, jsonMapOrNull((Map<?, ?>) call(source, "getLoginInfoMap")));
            cookies.put(id, cookieProbe(source));
        }
        JSONArray cookieRows = queryRows("select url, cookie from cookies order by url");
        JSONArray cacheKeys = queryRows("select `key` from caches order by `key`");
        inventory.put(step.getString("id"), new JSONObject()
            .put("cookieRows", cookieRows)
            .put("cacheKeys", cacheKeys));
        observe(step.getString("id"), new JSONObject()
            .put("kind", "state")
            .put("sessions", sessions)
            .put("loginHeaders", loginHeaders)
            .put("loginInfo", loginInfo)
            .put("cookies", cookies));
    }

    // ---------------------------------------------------------------- observations

    private JSONObject cookieProbe(Object source) throws Exception {
        String url = sourceUrl(sourceIdOf(source));
        String domain = domainOf(url);
        String persistent = String.valueOf(call(cookieManager(), "getCookieNoSession", url));
        Object session = call(cookieManager(), "getSessionCookie", domain);
        String effective = String.valueOf(call(cookieStore(), "getCookie", url));
        Object keys = call(cookieStore(), "cookieToMap", effective);
        return new JSONObject()
            .put("url", url)
            .put("domain", domain)
            .put("persistent", persistent)
            .put("session", session == null ? JSONObject.NULL : session)
            .put("effective", effective)
            .put("keys", jsonMap((Map<?, ?>) keys))
            .put("loginHeader", nullToNull(call(source, "getLoginHeader")))
            .put("loginHeaderMap", jsonMapOrNull((Map<?, ?>) call(source, "getLoginHeaderMap")));
    }

    private JSONArray loginUi(Object source) throws Exception {
        Object value = call(source, "loginUi");
        JSONArray rows = new JSONArray();
        if (value instanceof List) {
            for (Object row : (List<?>) value) {
                Class<?> type = row.getClass();
                rows.put(new JSONObject()
                    .put("name", str(type, row, "getName"))
                    .put("type", str(type, row, "getType"))
                    .put("action", nullToNull(call(type, row, "getAction"))));
            }
        }
        return rows;
    }

    private String checkValue(Object source, String key) throws Exception {
        Object value = call(source, "get", key);
        return value == null ? "" : value.toString();
    }

    private Object cookieStore() throws Exception {
        return loader.loadClass("io.legado.app.help.http.CookieStore")
            .getField("INSTANCE").get(null);
    }

    private Object cookieManager() throws Exception {
        return loader.loadClass("io.legado.app.help.http.CookieManager")
            .getField("INSTANCE").get(null);
    }

    private String sourceIdOf(Object source) throws Exception {
        String key = str(source.getClass(), source, "getBookSourceUrl");
        for (int index = 0; index < corpus.getJSONArray("sources").length(); index++) {
            JSONObject entry = corpus.getJSONArray("sources").getJSONObject(index);
            if (entry.getJSONObject("bookSource").getString("bookSourceUrl").equals(key)) {
                return entry.getString("id");
            }
        }
        throw new IllegalStateException("no corpus source for " + key);
    }

    private String sourceUrl(String id) throws JSONException {
        return corpus.getJSONArray("sources").getJSONObject(sourceIndex(id))
            .getJSONObject("bookSource").getString("bookSourceUrl");
    }

    private String sourceDomain(String id) throws JSONException {
        return domainOf(sourceUrl(id));
    }

    private int sourceIndex(String id) throws JSONException {
        JSONArray declared = corpus.getJSONArray("sources");
        for (int index = 0; index < declared.length(); index++) {
            if (declared.getJSONObject(index).getString("id").equals(id)) return index;
        }
        throw new IllegalStateException("corpus declares no source " + id);
    }

    private static String domainOf(String url) {
        try {
            return URI.create(url).getHost();
        } catch (Exception error) {
            throw new IllegalStateException("cannot parse source URL " + url, error);
        }
    }

    private JSONObject declaredBook(String id) throws JSONException {
        JSONArray declared = corpus.getJSONArray("books");
        for (int index = 0; index < declared.length(); index++) {
            JSONObject book = declared.getJSONObject(index);
            if (book.getString("id").equals(id)) return book;
        }
        throw new IllegalStateException("corpus declares no book " + id);
    }

    private static Object require(Map<String, Object> map, String id, String what) {
        Object value = map.get(id);
        if (value == null) throw new IllegalStateException("no " + what + " bound for " + id);
        return value;
    }

    private void observe(String id, Object value) throws JSONException {
        synchronized (observations) {
            observations.put(new JSONObject().put("id", id).put("value", value));
        }
    }

    // ------------------------------------------------------------ webview proof

    /**
     * Initializes the provider exactly once in this process, then measures the actual
     * provider identity and the PathUtils directories selected from the storage-only
     * application's context. A mismatch or an unavailable receipt fails before the
     * frozen removeCookie call; there is no default-profile fallback.
     */
    private JSONObject webViewPreflight() throws Exception {
        if (webViewReceipt != null) return webViewReceipt;
        if (webViewSuffixFailure != null) {
            throw new IllegalStateException("the WebView data-directory suffix could not be"
                + " set before provider initialization: " + webViewSuffixFailure);
        }
        if (application == null) {
            throw new IllegalStateException("the storage-only application is not bound");
        }
        JSONObject androidx = inspectAndroidXConfig(application.getClassLoader());
        if (!androidx.isNull("dataDirectoryBasePath")
                || !androidx.isNull("cacheDirectoryBasePath")
                || androidx.optBoolean("dataDirectorySuffixKey", false)) {
            throw new IllegalStateException("AndroidX ProcessGlobalConfig changes the WebView"
                + " data/cache base paths; refusing: " + androidx);
        }
        if (application.isDeviceProtectedStorage()) {
            throw new IllegalStateException("the storage-only application is device-protected;"
                + " WebView would replace it with a credential-protected context");
        }
        File computedData = application.getDir("webview_" + WEBVIEW_SUFFIX, Context.MODE_PRIVATE);
        File computedCache = new File(application.getCacheDir(), "webview_" + WEBVIEW_SUFFIX);
        File computedTextures = application.getDir("textures", Context.MODE_PRIVATE);
        requireInside("WebView data", computedData);
        requireInside("WebView cache", computedCache);
        requireInside("WebView textures", computedTextures);
        // The provider reads application.getApplicationContext() before it resolves the
        // paths. Refuse a replacement context before calling getDir on it; a real context
        // would create a real app_webview_<suffix> directory just by being asked.
        Context resolved = application.getApplicationContext();
        if (resolved != application) {
            throw new IllegalStateException("Application.getApplicationContext() replaced the"
                + " storage-only application with " + resolved.getClass().getName());
        }
        File resolvedData = resolved.getDir("webview_" + WEBVIEW_SUFFIX, Context.MODE_PRIVATE);
        File resolvedCache = new File(resolved.getCacheDir(), "webview_" + WEBVIEW_SUFFIX);
        File resolvedTextures = resolved.getDir("textures", Context.MODE_PRIVATE);
        requireInside("resolved WebView data", resolvedData);
        requireInside("resolved WebView cache", resolvedCache);
        requireInside("resolved WebView textures", resolvedTextures);
        if (!samePath(resolvedData, computedData) || !samePath(resolvedCache, computedCache)
                || !samePath(resolvedTextures, computedTextures)) {
            throw new IllegalStateException("resolved application context WebView paths differ");
        }
        JSONObject realBefore = realProfileState();
        JSONObject receipt = new JSONObject()
            .put("suffix", WEBVIEW_SUFFIX)
            .put("suffixStatus", "set-in-Instrumentation.newApplication")
            .put("androidxProcessGlobalConfig", androidx)
            .put("applicationClass", application.getClass().getName())
            .put("resolvedApplicationContextClass", resolved.getClass().getName())
            .put("resolvedApplicationContextIsApplication", true)
            .put("deviceProtected", application.isDeviceProtectedStorage())
            .put("computed", new JSONObject()
                .put("data", computedData.getCanonicalPath())
                .put("cache", computedCache.getCanonicalPath())
                .put("textures", computedTextures.getCanonicalPath()))
            .put("resolvedPaths", new JSONObject()
                .put("data", resolvedData.getCanonicalPath())
                .put("cache", resolvedCache.getCanonicalPath())
                .put("textures", resolvedTextures.getCanonicalPath()))
            .put("realProfileBefore", realBefore);
        CookieManager manager;
        try {
            manager = CookieManager.getInstance();
        } catch (Throwable error) {
            receipt.put("failure", "CookieManager.getInstance: " + describe(error));
            throw new IllegalStateException("WebView provider initialization failed: "
                + describe(error));
        }
        PackageInfo provider = WebView.getCurrentWebViewPackage();
        if (provider == null) {
            receipt.put("failure", "WebView.getCurrentWebViewPackage() returned null");
            throw new IllegalStateException("WebView provider identity is unavailable");
        }
        JSONObject expectedProvider = corpus.getJSONObject("webViewProvider");
        if (!expectedProvider.getString("package").equals(provider.packageName)
                || !expectedProvider.getString("versionName").equals(provider.versionName)) {
            receipt.put("failure", "provider is " + provider.packageName + " "
                + provider.versionName + ", corpus pins " + expectedProvider);
            throw new IllegalStateException("WebView provider identity is not the corpus pin: "
                + provider.packageName + " " + provider.versionName);
        }
        receipt.put("provider", new JSONObject()
            .put("package", provider.packageName)
            .put("versionName", provider.versionName)
            .put("versionCode", provider.getLongVersionCode())
            .put("source", expectedProvider.optString("source", "")))
            .put("providerClass", manager.getClass().getName());
        JSONObject actual = providerPaths(manager.getClass().getClassLoader());
        receipt.put("actual", actual);
        if (!samePath(actual.getString("data"), computedData)
                || !samePath(actual.getString("cache"), computedCache)
                || !samePath(actual.getString("textures"), computedTextures)) {
            receipt.put("failure", "provider PathUtils directories differ from the approved"
                + " scratch paths");
            throw new IllegalStateException("provider PathUtils directories differ: " + actual);
        }
        JSONObject realAfter = realProfileState();
        receipt.put("realProfileAfter", realAfter);
        if (!realProfileSame(realBefore, realAfter)) {
            receipt.put("failure", "a real app_webview path appeared or changed during"
                + " provider initialization");
            throw new IllegalStateException("real WebView profile metadata changed");
        }
        receipt.put("listings", new JSONObject()
            .put("data", listing(computedData))
            .put("cache", listing(computedCache))
            .put("textures", listing(computedTextures)));
        receipt.put("pathSource", "org.chromium.base.PathUtils via provider classloader");
        webViewReceipt = receipt;
        return receipt;
    }

    private JSONObject inspectAndroidXConfig(ClassLoader appLoader) throws Exception {
        JSONObject result = new JSONObject()
            .put("classPresent", false)
            .put("configSet", false)
            .put("dataDirectoryBasePath", JSONObject.NULL)
            .put("cacheDirectoryBasePath", JSONObject.NULL)
            .put("dataDirectorySuffixKey", false);
        Class<?> holder;
        try {
            holder = Class.forName("androidx.webkit.ProcessGlobalConfig", true, appLoader);
        } catch (ClassNotFoundException | NoClassDefFoundError absent) {
            return result;
        }
        result.put("classPresent", true);
        Field field = holder.getDeclaredField("sProcessGlobalConfig");
        field.setAccessible(true);
        Object reference = field.get(null);
        if (reference == null) return result;
        Object map = reference.getClass().getMethod("get").invoke(reference);
        if (map == null) return result;
        result.put("configSet", true);
        Map<?, ?> values = (Map<?, ?>) map;
        Object data = values.get("DATA_DIRECTORY_BASE_PATH");
        Object cache = values.get("CACHE_DIRECTORY_BASE_PATH");
        result.put("dataDirectoryBasePath", data == null ? JSONObject.NULL : data.toString())
            .put("cacheDirectoryBasePath", cache == null ? JSONObject.NULL : cache.toString())
            .put("dataDirectorySuffixKey", values.containsKey("DATA_DIRECTORY_SUFFIX"));
        return result;
    }

    private JSONObject providerPaths(ClassLoader providerLoader) throws Exception {
        Class<?> pathUtils = null;
        String loadedFrom = "";
        List<ClassLoader> candidates = new ArrayList<>();
        if (providerLoader != null) candidates.add(providerLoader);
        if (getTargetContext().getClassLoader() != null) {
            candidates.add(getTargetContext().getClassLoader());
        }
        // The provider adapter's loader normally owns PathUtils. If it does not, ask the
        // already-initialized framework factory once; a hidden-API refusal is ignored.
        try {
            Class<?> factory = Class.forName("android.webkit.WebViewFactory");
            Method getProvider = factory.getDeclaredMethod("getProvider");
            getProvider.setAccessible(true);
            Object provider = getProvider.invoke(null);
            if (provider != null && provider.getClass().getClassLoader() != null) {
                candidates.add(provider.getClass().getClassLoader());
            }
        } catch (Throwable ignored) {
            // The provider-loader candidate remains the documented path.
        }
        for (int index = 0; index < candidates.size(); index++) {
            try {
                pathUtils = Class.forName("org.chromium.base.PathUtils", true,
                    candidates.get(index));
                loadedFrom = "provider-classloader-" + index;
                break;
            } catch (ClassNotFoundException | NoClassDefFoundError ignored) {
                // Try the next candidate.
            }
        }
        if (pathUtils == null) {
            throw new IllegalStateException("org.chromium.base.PathUtils is unavailable from the"
                + " provider classloader; provider path receipt cannot be established");
        }
        return new JSONObject()
            .put("loadedFrom", loadedFrom)
            .put("data", canonical(staticString(pathUtils, "getDataDirectory")))
            .put("cache", canonical(staticString(pathUtils, "getCacheDirectory")))
            .put("textures", canonical(staticString(pathUtils, "getThumbnailCacheDirectory")));
    }

    private String staticString(Class<?> owner, String name) throws Exception {
        try {
            return (String) owner.getMethod(name).invoke(null);
        } catch (InvocationTargetException error) {
            Throwable cause = error.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            throw new IllegalStateException(cause);
        }
    }

    private JSONObject realProfileState() throws Exception {
        String dataDir = getTargetContext().getApplicationInfo().dataDir;
        return new JSONObject()
            .put("dataDir", dataDir)
            .put("app_webview", fileMeta(new File(dataDir, "app_webview")))
            .put("app_webview_suffixed", fileMeta(new File(dataDir,
                "app_webview_" + WEBVIEW_SUFFIX)))
            .put("note", "existence/size/mtime metadata only; contents are not inspected");
    }

    private JSONObject fileMeta(File file) throws Exception {
        return new JSONObject()
            .put("path", file.getCanonicalPath())
            .put("exists", file.exists())
            .put("directory", file.isDirectory())
            .put("length", file.length())
            .put("lastModified", file.lastModified());
    }

    private boolean realProfileSame(JSONObject before, JSONObject after) throws Exception {
        for (String key : new String[]{"app_webview", "app_webview_suffixed"}) {
            JSONObject left = before.getJSONObject(key);
            JSONObject right = after.getJSONObject(key);
            if (left.getBoolean("exists") != right.getBoolean("exists")
                    || left.getBoolean("directory") != right.getBoolean("directory")
                    || left.getLong("length") != right.getLong("length")
                    || left.getLong("lastModified") != right.getLong("lastModified")) {
                return false;
            }
        }
        return true;
    }

    private JSONArray listing(File directory) {
        JSONArray names = new JSONArray();
        File[] files = directory.listFiles();
        if (files == null) return names;
        List<String> sorted = new ArrayList<>();
        for (File file : files) sorted.add(file.getName());
        Collections.sort(sorted);
        for (String name : sorted) names.put(name);
        return names;
    }

    private void requireInside(String what, File file) throws Exception {
        String root = scratch.root.getCanonicalPath();
        String path = file.getCanonicalPath();
        if (!path.equals(root) && !path.startsWith(root + File.separator)) {
            throw new IllegalStateException(what + " escaped the AUTH scratch root: " + path);
        }
    }

    private static boolean samePath(String path, File expected) throws Exception {
        return new File(path).getCanonicalPath().equals(expected.getCanonicalPath());
    }

    private static boolean samePath(File actual, File expected) throws Exception {
        return actual.getCanonicalPath().equals(expected.getCanonicalPath());
    }

    private static String canonical(String path) throws Exception {
        return new File(path).getCanonicalPath();
    }

    private JSONObject webViewReport() throws JSONException {
        return new JSONObject()
            .put("suffix", WEBVIEW_SUFFIX)
            .put("suffixStatus", webViewSuffixFailure == null
                ? "set-in-Instrumentation.newApplication" : "refused")
            .put("suffixFailure", webViewSuffixFailure == null
                ? JSONObject.NULL : webViewSuffixFailure)
            .put("preflightFailure", webViewPreflightFailure == null
                ? JSONObject.NULL : webViewPreflightFailure)
            .put("preflight", webViewReceipt == null ? JSONObject.NULL : webViewReceipt);
    }

    // -------------------------------------------------------------- completeness

    private JSONObject requestCheck() throws Exception {
        JSONArray declared = phaseSpec.getJSONArray("expectedRequests");
        JSONArray actual = snapshot(requests);
        JSONArray mismatches = new JSONArray();
        boolean match = declared.length() == actual.length();
        for (int index = 0; index < declared.length(); index++) {
            JSONObject expected = declared.getJSONObject(index);
            JSONObject observed = actual.optJSONObject(index);
            if (observed == null) {
                match = false;
                mismatches.put(new JSONObject().put("index", index).put("reason", "missing"));
                continue;
            }
            String expectedBody = expected.optString("body", "");
            String expectedHash = sha256(expectedBody.getBytes(StandardCharsets.UTF_8));
            boolean row = expected.getString("method").equals(observed.optString("method"))
                && expected.getString("path").equals(observed.optString("path"))
                && expected.getString("rawQuery").equals(observed.optString("rawQuery"))
                && expectedBody.equals(observed.optString("body"))
                && expectedHash.equals(observed.optString("bodySha256"));
            if (!row) {
                match = false;
                mismatches.put(new JSONObject()
                    .put("index", index)
                    .put("expected", expected)
                    .put("actual", new JSONObject()
                        .put("method", observed.optString("method"))
                        .put("path", observed.optString("path"))
                        .put("rawQuery", observed.optString("rawQuery"))
                        .put("body", observed.optString("body"))
                        .put("bodySha256", observed.optString("bodySha256"))));
            }
        }
        JSONArray forbidden = new JSONArray();
        JSONArray names = corpus.getJSONObject("requestChecks").getJSONArray("forbiddenHeaders");
        for (int index = 0; index < actual.length(); index++) {
            JSONObject headers = actual.getJSONObject(index).optJSONObject("headers");
            if (headers == null) continue;
            for (int nameIndex = 0; nameIndex < names.length(); nameIndex++) {
                String name = names.getString(nameIndex).toLowerCase(Locale.US);
                if (headers.has(name)) {
                    forbidden.put(new JSONObject()
                        .put("index", index)
                        .put("header", name));
                }
            }
        }
        return new JSONObject()
            .put("declared", declared)
            .put("actual", actual)
            .put("mismatches", mismatches)
            .put("orderMatch", match)
            .put("bodyMatch", match)
            .put("unmatched", unmatched.length())
            .put("serverErrors", serverErrors.length())
            .put("forbiddenHeaders", forbidden)
            .put("match", match && unmatched.length() == 0 && serverErrors.length() == 0
                && forbidden.length() == 0);
    }

    private JSONObject observationCheck() throws Exception {
        JSONArray declared = new JSONArray();
        JSONArray steps = phaseSpec.getJSONArray("steps");
        for (int index = 0; index < steps.length(); index++) {
            declared.put(steps.getJSONObject(index).getString("id"));
        }
        JSONArray actual = new JSONArray();
        Set<String> declaredSet = new LinkedHashSet<>();
        Set<String> actualSet = new LinkedHashSet<>();
        JSONArray duplicates = new JSONArray();
        for (int index = 0; index < declared.length(); index++) {
            declaredSet.add(declared.getString(index));
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
        return new JSONObject()
            .put("declared", declared)
            .put("actual", actual)
            .put("missing", missing)
            .put("extra", extra)
            .put("duplicates", duplicates)
            .put("ordered", ordered)
            .put("match", missing.length() == 0 && extra.length() == 0
                && ordered && duplicates.length() == 0);
    }

    // ------------------------------------------------------------------ cleanup

    private JSONObject cleanup(boolean succeeded) throws Exception {
        JSONObject cleanup = new JSONObject();
        cleanupOk = false;
        boolean databaseClosed = false;
        boolean replayOk = false;
        if (database != null) {
            try {
                call(database, "close");
                databaseClosed = true;
                cleanup.put("databaseClosed", true);
            } catch (Throwable error) {
                cleanup.put("databaseClosed", false).put("databaseError", describe(error));
            }
            database = null;
        } else {
            cleanup.put("databaseClosed", false)
                .put("databaseNote", "the phase never opened the database");
        }
        if (replay != null) {
            try {
                cleanup.put("replay", replay.closeAndReport());
                replayOk = replay.cleanupOk();
            } catch (Throwable error) {
                cleanup.put("serverClosed", false).put("serverError", describe(error));
            }
            replay = null;
        } else {
            cleanup.put("serverClosed", false)
                .put("serverNote", "the phase never started the replay listeners");
        }
        boolean terminalOk = finalTerminalSnapshot(cleanup);
        if (!scratch.isBound()) {
            cleanup.put("ownership", "none: the phase never established ownership, prior state"
                + " left intact")
                .put("scratchRoot", scratch.root.getAbsolutePath())
                .put("scratchRootExistedAtStart", scratch.rootExistedAtStart())
                .put("scratchRetained", scratch.root.exists())
                .put("scratchRemoved", false)
                .put("preferencesRemoved", new JSONArray());
            return cleanup;
        }
        boolean seed = "seed".equals(phase);
        cleanup.put("ownership", seed ? "created-fresh-root" : "validated-seed-owner")
            .put("scratchRoot", scratch.root.getAbsolutePath());
        if (seed && succeeded) {
            JSONArray fenced = new JSONArray();
            boolean allFenced = true;
            for (String name : scratch.ownedPreferences()) {
                boolean fencedOk = scratch.fence(name);
                allFenced &= fencedOk;
                fenced.put(new JSONObject().put("name", name).put("ok", fencedOk));
            }
            boolean retained = scratch.root.isDirectory();
            cleanup.put("preferencesFenced", fenced)
                .put("preferencesRemoved", new JSONArray())
                .put("scratchRetained", retained)
                .put("scratchRemoved", false)
                .put("ownerFile", new File(scratch.root, OWNER_FILE).getAbsolutePath());
            cleanupOk = databaseClosed && replayOk && terminalOk && allFenced && retained;
            if (!allFenced) {
                cleanup.put("cleanupFailure", "not every owned preference could be fenced;"
                    + " the seed is not complete");
            } else if (!retained) {
                cleanup.put("cleanupFailure", "the retained scratch root is not there;"
                    + " the seed is not complete");
            } else if (!cleanupOk) {
                cleanup.put("cleanupFailure", "databaseClosed=" + databaseClosed
                    + " replayOk=" + replayOk + " terminalOk=" + terminalOk);
            }
            if (cleanupOk) scratch.writeOwnerComplete(runId);
        } else {
            JSONArray removed = new JSONArray();
            boolean allRemoved = true;
            for (String name : scratch.ownedPreferences()) {
                boolean removedOk = scratch.deletePreference(name);
                allRemoved &= removedOk;
                removed.put(new JSONObject().put("name", name).put("ok", removedOk));
            }
            boolean rootRemoved = scratch.removeRoot();
            cleanup.put("preferencesFenced", new JSONArray())
                .put("preferencesRemoved", removed)
                .put("scratchRetained", !rootRemoved && scratch.root.exists())
                .put("scratchRemoved", rootRemoved);
            cleanupOk = databaseClosed && replayOk && terminalOk && allRemoved && rootRemoved;
            if (!cleanupOk) {
                cleanup.put("cleanupFailure", "databaseClosed=" + databaseClosed
                    + " replayOk=" + replayOk + " terminalOk=" + terminalOk
                    + " everyPreferenceRemoved=" + allRemoved
                    + " rootRemoved=" + rootRemoved);
            }
        }
        return cleanup;
    }

    /**
     * Takes the final request/observation/error snapshot after the listeners, workers
     * and clients have stopped. This is the phase's terminal correctness gate: a late
     * server error, an undeclared request or an incomplete/reordered request set cannot
     * pass a previously cached check, and the report keeps this final snapshot.
     */
    private boolean finalTerminalSnapshot(JSONObject cleanup) {
        JSONObject terminal = new JSONObject();
        try {
            requestCheckValue = requestCheck();
            observationCheckValue = observationCheck();
            boolean requestOk = requestCheckValue.optBoolean("match", false);
            boolean observationOk = observationCheckValue.optBoolean("match", false);
            boolean errorsEmpty = serverErrors.length() == 0;
            boolean unmatchedEmpty = unmatched.length() == 0;
            boolean ok = requestOk && observationOk && errorsEmpty && unmatchedEmpty;
            terminal.put("requests", requests.length())
                .put("unmatched", unmatched.length())
                .put("serverErrors", serverErrors.length())
                .put("requestMatch", requestOk)
                .put("observationMatch", observationOk)
                .put("ok", ok);
            cleanup.put("terminal", terminal);
            return ok;
        } catch (Throwable error) {
            try {
                requestCheckValue = new JSONObject().put("match", false)
                    .put("error", describe(error));
                observationCheckValue = new JSONObject().put("match", false)
                    .put("error", describe(error));
                terminal.put("ok", false).put("error", describe(error));
                cleanup.put("terminal", terminal);
            } catch (JSONException ignored) {
                // The failure is already visible through cleanupOk and the phase failure.
            }
            return false;
        }
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

    // ---------------------------------------------------------------- corpus checks

    private void validateCorpus() throws Exception {
        if (!"AUTH-SESSION-01".equals(corpus.getString("fixtureId"))
                || corpus.getInt("schemaVersion") != 1) {
            throw new IllegalStateException("corpus is not AUTH-SESSION-01 schema 1");
        }
        JSONObject target = corpus.getJSONObject("target");
        if (!target.getString("package").equals("io.legado.app.debug")) {
            throw new IllegalStateException("corpus targets another package");
        }
        JSONObject provider = corpus.getJSONObject("webViewProvider");
        if (provider.getString("package").isEmpty()
                || provider.getString("versionName").isEmpty()) {
            throw new IllegalStateException("corpus pins no WebView provider");
        }
        JSONArray origins = new JSONArray();
        JSONArray originKeys = new JSONArray();
        JSONObject originMap = corpus.getJSONObject("origins");
        Iterator<String> originNames = originMap.keys();
        while (originNames.hasNext()) originKeys.put(originNames.next());
        for (int index = 0; index < originKeys.length(); index++) {
            String key = originKeys.getString(index);
            String value = originMap.getString(key);
            URI uri = URI.create(value);
            if (uri.getHost() == null || uri.getPort() < 1) {
                throw new IllegalStateException("origin " + key + " is not an explicit host:port");
            }
            origins.put(uri.getHost());
        }
        Set<String> hosts = new LinkedHashSet<>();
        for (int index = 0; index < origins.length(); index++) hosts.add(origins.getString(index));
        if (hosts.size() != 2 || !hosts.contains("127.0.0.1") || !hosts.contains("127.0.0.2")) {
            throw new IllegalStateException("corpus must name the two explicit loopback hosts, got "
                + hosts);
        }
        JSONArray sources = corpus.getJSONArray("sources");
        if (sources.length() != 2) throw new IllegalStateException("corpus needs two sources");
        boolean jarOn = false;
        boolean jarOff = false;
        for (int index = 0; index < sources.length(); index++) {
            JSONObject source = sources.getJSONObject(index).getJSONObject("bookSource");
            if (source.optBoolean("enabledCookieJar")) jarOn = true; else jarOff = true;
            if (source.optString("loginUrl").isEmpty()) {
                throw new IllegalStateException("source has no login script");
            }
        }
        if (!jarOn || !jarOff) {
            throw new IllegalStateException("corpus must cover enabledCookieJar on and off");
        }
        JSONArray responses = corpus.getJSONArray("responses");
        Set<String> responseIds = new LinkedHashSet<>();
        for (int index = 0; index < responses.length(); index++) {
            JSONObject response = responses.getJSONObject(index);
            if (!responseIds.add(response.getString("id"))) {
                throw new IllegalStateException("duplicate response id " + response.getString("id"));
            }
            if (!response.has("method") || !response.has("path")
                    || !response.has("rawQuery") || !response.has("body")) {
                throw new IllegalStateException("response " + response.optString("id")
                    + " is missing a mandatory field");
            }
        }
        JSONArray books = corpus.getJSONArray("books");
        Set<String> bookIds = new LinkedHashSet<>();
        for (int index = 0; index < books.length(); index++) {
            JSONObject book = books.getJSONObject(index);
            if (!bookIds.add(book.getString("id"))) {
                throw new IllegalStateException("duplicate book id " + book.getString("id"));
            }
        }
        for (String phaseName : new String[]{"seed", "restart"}) {
            JSONObject phaseValue = corpus.getJSONObject("phases").getJSONObject(phaseName);
            JSONArray steps = phaseValue.getJSONArray("steps");
            Set<String> stepIds = new LinkedHashSet<>();
            for (int index = 0; index < steps.length(); index++) {
                JSONObject step = steps.getJSONObject(index);
                if (!stepIds.add(step.getString("id"))) {
                    throw new IllegalStateException("duplicate step id " + step.getString("id"));
                }
                if (!new LinkedHashSet<>(java.util.Arrays.asList("login", "headerMap",
                        "stage", "cookieState", "cookieKeyRemoval", "removeLoginHeader",
                        "loginHeaderPut", "state")).contains(step.getString("kind"))) {
                    throw new IllegalStateException("unknown step kind " + step.getString("kind"));
                }
            }
            JSONArray expected = phaseValue.getJSONArray("expectedRequests");
            Set<String> selectors = new LinkedHashSet<>();
            for (int index = 0; index < expected.length(); index++) {
                JSONObject request = expected.getJSONObject(index);
                selectors.add(selectorOf(request));
            }
            Set<String> active = new LinkedHashSet<>();
            for (int index = 0; index < responses.length(); index++) {
                JSONObject response = responses.getJSONObject(index);
                if (response.has("phase") && !phaseName.equals(response.getString("phase"))) {
                    continue;
                }
                String selector = selectorOf(response);
                if (!active.add(selector)) {
                    throw new IllegalStateException("two active responses select " + selector);
                }
            }
            for (String selector : selectors) {
                if (!active.contains(selector)) {
                    throw new IllegalStateException("no response for declared request " + selector);
                }
            }
        }
        if (corpus.getJSONObject("requestChecks").getJSONArray("forbiddenHeaders").length() == 0) {
            throw new IllegalStateException("corpus declares no forbidden request headers");
        }
    }

    private static String selectorOf(JSONObject value) throws JSONException {
        return value.getString("method") + " " + value.getString("path") + "?"
            + value.optString("rawQuery", "");
    }

    // ---------------------------------------------------------------- reflection

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
                        return "auth-session-oracle-block";
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

    private static Object call(Class<?> owner, Object instance, String name, int parameterCount,
            Object[] arguments, Object continuation) throws Throwable {
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
        throw new IllegalStateException("table of contents result is "
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
                Throwable cause = error.getCause();
                if (cause instanceof Exception) throw (Exception) cause;
                throw new IllegalStateException(cause);
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

    private static Object call(Class<?> owner, Object instance, String name, Object... args)
            throws Exception {
        for (Method method : owner.getMethods()) {
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
                return method.invoke(instance, args);
            } catch (InvocationTargetException error) {
                Throwable cause = error.getCause();
                if (cause instanceof Exception) throw (Exception) cause;
                throw new IllegalStateException(cause);
            }
        }
        throw new IllegalStateException("no method " + name + " with " + args.length
            + " arguments on " + owner.getName());
    }

    private static String str(Class<?> type, Object target, String getter) throws Exception {
        Object value = type.getMethod(getter).invoke(target);
        return value == null ? "" : value.toString();
    }

    // ---------------------------------------------------------------- report helpers

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
                .put("phase", phase == null ? "" : phase)
                .put("runId", runId == null ? "" : runId)
                .put("pid", android.os.Process.myPid())
                .put("timedOut", true)
                .put("timeoutStage", where)
                .put("requests", snapshot(requests))
                .put("stageTrace", snapshot(stageTrace))
                .put("unmatchedRequests", snapshot(unmatched))
                .put("serverErrors", snapshot(serverErrors))
                .put("observations", snapshot(observations))
                .put("webView", webViewReport())
                .put("analysisFailure", "timeout: no result after 240s in stage " + where);
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
            Object value = map.get(key);
            if (value == null) {
                for (Map.Entry<?, ?> entry : map.entrySet()) {
                    if (String.valueOf(entry.getKey()).equals(key)) {
                        value = entry.getValue();
                        break;
                    }
                }
            }
            pairs.put(new JSONArray().put(key)
                .put(value == null ? JSONObject.NULL : String.valueOf(value)));
        }
        return pairs;
    }

    private static Object jsonMapOrNull(Map<?, ?> map) throws JSONException {
        return map == null ? JSONObject.NULL : jsonMap(map);
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

    // ---------------------------------------------------------------- replay

    /**
     * Two explicit loopback listeners, one per corpus source host, on the same declared
     * port. A failed bind closes the other and fails; there is no wildcard fallback and
     * no alternate port. Each request is matched by method, path and the exact raw query
     * bytes the client sent.
     */
    private static final class AuthReplay {
        private static final long CLOSE_WAIT_MILLIS = 4000;

        private final JSONArray active;
        private final JSONArray requests;
        private final JSONArray unmatched;
        private final JSONArray serverErrors;
        private final JSONArray stageTrace;
        private final AtomicReference<String> stage;
        private final List<Listener> listeners = new ArrayList<>();
        private final ExecutorService clients = Executors.newFixedThreadPool(4);
        private final Set<Socket> openSockets = new java.util.HashSet<>();
        private final AtomicInteger open = new AtomicInteger();
        private final AtomicBoolean closing = new AtomicBoolean();
        private final JSONArray listenerCloseErrors = new JSONArray();
        private volatile boolean listenersClosed;
        private volatile boolean workersStopped;
        private volatile boolean executorTerminated;
        private volatile int openBeforeClose;
        private volatile int openAfterClose = -1;

        AuthReplay(JSONObject corpus, String phase, JSONArray requests, JSONArray unmatched,
                JSONArray serverErrors, JSONArray stageTrace, AtomicReference<String> stage)
                throws Exception {
            this.requests = requests;
            this.unmatched = unmatched;
            this.serverErrors = serverErrors;
            this.stageTrace = stageTrace;
            this.stage = stage;
            JSONObject origins = corpus.getJSONObject("origins");
            Iterator<String> names = origins.keys();
            List<URI> uris = new ArrayList<>();
            while (names.hasNext()) {
                String name = names.next();
                URI uri = URI.create(origins.getString(name));
                uris.add(uri);
                if (uris.size() <= 1) continue;
                if (uri.getPort() != uris.get(0).getPort()) {
                    throw new IllegalStateException("corpus origins use different ports");
                }
            }
            if (uris.size() != 2) throw new IllegalStateException("corpus needs two origins");
            for (URI uri : uris) {
                listeners.add(new Listener(uri.getHost(), uri.getPort()));
            }
            this.active = new JSONArray();
            JSONArray declared = corpus.getJSONArray("responses");
            Set<String> selectors = new LinkedHashSet<>();
            for (int index = 0; index < declared.length(); index++) {
                JSONObject response = declared.getJSONObject(index);
                String scoped = response.optString("phase", "");
                if (!scoped.isEmpty() && !scoped.equals(phase)) continue;
                String selector = selectorOf(response);
                if (!selectors.add(selector)) {
                    throw new IllegalStateException("two active responses select " + selector);
                }
                active.put(response);
            }
        }

        String endpoints() throws Exception {
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
                    // Register the local resource before bind, so a failed bind is also
                    // closed and reported instead of leaking an unassigned socket.
                    listener.server = server;
                    listener.created = true;
                    server.setReuseAddress(true);
                    server.bind(new InetSocketAddress(InetAddress.getByName(listener.host),
                        listener.port), 16);
                }
            } catch (Throwable error) {
                for (Listener listener : listeners) closeListener(listener);
                throw new IllegalStateException("replay listener bind failed: " + describe(error),
                    error);
            }
            for (Listener listener : listeners) {
                listener.worker = new Thread(() -> accept(listener),
                    "auth-replay-" + listener.host);
                listener.worker.setDaemon(true);
                listener.worker.start();
            }
        }

        int openConnections() {
            return open.get();
        }

        JSONObject closeAndReport() throws Exception {
            openBeforeClose = open.get();
            closing.set(true);
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
                failures.put("server errors during the phase: " + serverErrors.length());
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
            while (!closing.get() && listener.server != null && !listener.server.isClosed()) {
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
                            if (!closing.get()) {
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
                    if (!closing.get() && listener.server != null && !listener.server.isClosed()) {
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
                JSONObject observed = new JSONObject()
                    .put("listener", listener.host)
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
                        ? bodyBytes : java.util.Arrays.copyOf(bodyBytes, read)))
                    .put("stage", stage.get());
                synchronized (requests) {
                    requests.put(observed);
                    synchronized (stageTrace) {
                        stageTrace.put(new JSONObject()
                            .put("stage", stage.get())
                            .put("listener", listener.host)
                            .put("target", target));
                    }
                }
                JSONObject declared = match(method, path, rawQuery);
                if (declared == null) {
                    synchronized (unmatched) {
                        unmatched.put(observed);
                    }
                    byte[] text = "undeclared replay request".getBytes(StandardCharsets.UTF_8);
                    output.write(("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
                        + "Content-Length: " + text.length + "\r\nConnection: keep-alive\r\n\r\n")
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
                        Iterator<String> headerNames = declaredHeaders.keys();
                        while (headerNames.hasNext()) {
                            String name = headerNames.next();
                            head.append(name).append(": ")
                                .append(declaredHeaders.optString(name)).append("\r\n");
                        }
                    }
                    JSONArray setCookies = declared.optJSONArray("setCookies");
                    if (setCookies != null) {
                        for (int index = 0; index < setCookies.length(); index++) {
                            head.append("Set-Cookie: ").append(setCookies.getString(index))
                                .append("\r\n");
                        }
                    }
                    head.append("Content-Length: ").append(bytes.length)
                        .append("\r\nConnection: keep-alive\r\n\r\n");
                    output.write(head.toString().getBytes(StandardCharsets.US_ASCII));
                    output.write(bytes);
                }
                output.flush();
            }
        }

        private JSONObject match(String method, String path, String rawQuery) {
            for (int index = 0; index < active.length(); index++) {
                JSONObject response = active.optJSONObject(index);
                if (response == null) continue;
                if (method.equals(response.optString("method"))
                        && path.equals(response.optString("path"))
                        && rawQuery.equals(response.optString("rawQuery", ""))) {
                    return response;
                }
            }
            return null;
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
}
