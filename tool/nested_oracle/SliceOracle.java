package io.liber.oracle.nested;

import android.app.Instrumentation;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import org.json.JSONArray;
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
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The frozen side of the SLICE-01 four-stage corpus: drives
 * {@code io.legado.app.model.webBook.WebBook}'s four suspend entry points against
 * the installed, hash-pinned {@code io.legado.app.debug}, and serves
 * {@code tool/first_slice/fixtures.json} on the port the corpus names, inside this
 * process. No Legado class is rebuilt; every entry point is reached by reflection.
 *
 * <p>The work is posted to the main looper because the target application is
 * created after {@link #onCreate}, and the frozen HTTP stack and its cookie store
 * have to be past that point. It then runs on its own thread, because the four
 * suspend calls are driven with {@code kotlinx.coroutines.runBlocking}.
 *
 * <p>The report's shape follows the one {@code NestedOracle}/{@code StateOracle}
 * write, so {@code tool/first_slice_compare.dart} can read it against the
 * Liber-side observation.
 */
public final class SliceOracle extends Instrumentation {

    private final JSONArray requests = new JSONArray();
    private final JSONArray unmatched = new JSONArray();
    private final JSONArray serverErrors = new JSONArray();
    private final JSONArray stageTrace = new JSONArray();
    private final AtomicReference<String> stage = new AtomicReference<>("setup");
    private final java.util.concurrent.atomic.AtomicBoolean finished =
        new java.util.concurrent.atomic.AtomicBoolean();

    private JSONObject corpus;
    private SliceReplay replay;

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        log("onCreate");
        new Handler(Looper.getMainLooper()).post(() -> {
            log("main looper reached; starting the worker thread");
            new Thread(this::run, "slice-oracle").start();
        });
        startWatchdog();
    }

    /**
     * An instrumentation that never finishes reports nothing on the host, so a
     * stalled stage has to surface as a result rather than as silence.
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
                status.putString("stream", "Slice oracle timed out in stage " + stage.get()
                    + " after " + requests.length() + " requests\n");
                finish(1, status);
            }
        }, "slice-oracle-watchdog");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    private void log(String message) {
        Log.i("SliceOracle", message);
    }

    private void run() {
        Bundle status = new Bundle();
        try {
            log("harness start");
            corpus = new JSONObject(readAsset("slice-fixtures.json"));
            log("corpus loaded: " + corpus.getString("fixtureId"));
            JSONObject cleanup = new JSONObject();
            JSONObject state = new JSONObject();
            JSONObject stages = new JSONObject();
            String failure = null;
            replay = new SliceReplay(corpus, requests, unmatched, serverErrors, stageTrace, stage);
            replay.start();
            log("replay server bound to 127.0.0.1:18731");
            try {
                drive(stages, state);
            } catch (Throwable error) {
                failure = describe(error);
                log("stage " + stage.get() + " failed: " + failure);
            }
            // The report is written before the replay server is torn down: the run's
            // evidence must survive a host that freezes this process after a few
            // seconds (MIUI does; see the golden's manifest).
            JSONObject report = new JSONObject()
                .put("fixtureId", corpus.getString("fixtureId"))
                .put("corpusVersion", corpus.getInt("corpusVersion"))
                .put("baselineCommit", corpus.getString("baselineCommit"))
                .put("entryPoint", corpus.getString("entryPoint"))
                .put("platform", "android")
                .put("fingerprint", Build.FINGERPRINT)
                .put("recordedAt", timestamp())
                .put("requests", requests)
                .put("unmatchedRequests", unmatched)
                .put("serverErrors", serverErrors)
                .put("stageTrace", stageTrace)
                .put("stages", stages)
                .put("state", state)
                .put("cleanup", cleanup)
                .put("analysisFailure", failure == null ? JSONObject.NULL : failure);
            File output = new File(getTargetContext().getExternalFilesDir(null), "slice-oracle.json");
            try (FileOutputStream stream = new FileOutputStream(output)) {
                stream.write(report.toString(2).getBytes(StandardCharsets.UTF_8));
            }
            log("report written; failure=" + failure);
            status.putString("stream", failure == null
                ? "Slice oracle recorded " + requests.length() + " requests\n"
                : "Slice oracle failed: " + failure + "\n");
            finished.set(true);
            finish(failure == null ? -1 : 1, status);
            stage.set("cleanup");
            cleanup.put("openConnections", replay.openConnections());
            try {
                replay.close();
                cleanup.put("serverClosed", true);
            } catch (Throwable error) {
                cleanup.put("serverClosed", false);
                log("cleanup failed: " + describe(error));
            }
        } catch (Throwable error) {
            status.putString("stream", "Slice oracle harness error: " + describe(error) + "\n");
            log("harness error: " + describe(error));
            finished.set(true);
            finish(1, status);
        }
    }

    /** The four stages, in the corpus' order, through the frozen entry points. */
    private void drive(JSONObject stages, JSONObject state) throws Exception {
        ClassLoader loader = getTargetContext().getClassLoader();
        JSONObject sourceJson = corpus.getJSONObject("source");
        String keyword = corpus.getString("keyword");

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
        state.put("bookSourceUrl", str(bookSourceClass, source, "getBookSourceUrl"));

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
                .put("kind", str(searchBookClass, item, "getKind"))
                .put("bookUrl", str(searchBookClass, item, "getBookUrl")));
        }
        stages.put("search", new JSONObject().put("results", results));
        if (list.isEmpty()) throw new IllegalStateException("search returned no result");
        Object book = searchBookClass.getMethod("toBook").invoke(list.get(0));

        stage.set("bookInfo");
        log("stage bookInfo");
        runSuspend(loader, continuation -> call(webBookClass, webBook,
            "getBookInfoAwait", 4,
            new Object[]{source, book, Boolean.TRUE}, continuation));
        log("stage bookInfo returned");
        stages.put("bookInfo", new JSONObject()
            .put("name", str(bookClass, book, "getName"))
            .put("author", str(bookClass, book, "getAuthor"))
            .put("kind", str(bookClass, book, "getKind"))
            .put("lastChapter", str(bookClass, book, "getLatestChapterTitle"))
            .put("cover", str(bookClass, book, "getCoverUrl"))
            .put("intro", str(bookClass, book, "getIntro"))
            .put("tocUrl", str(bookClass, book, "getTocUrl")));

        stage.set("tableOfContents");
        log("stage tableOfContents");
        Object tocResult = runSuspend(loader, continuation -> call(webBookClass, webBook,
            "getChapterListAwait", 4,
            new Object[]{source, book, Boolean.FALSE}, continuation));
        log("stage tableOfContents returned");
        List<?> chapters = unwrapResult(tocResult);
        JSONArray chapterArray = new JSONArray();
        JSONArray chapterAbsolute = new JSONArray();
        for (Object chapter : chapters) {
            chapterArray.put(new JSONObject()
                .put("name", str(chapterClass, chapter, "getTitle"))
                .put("url", str(chapterClass, chapter, "getUrl")));
            chapterAbsolute.put(str(chapterClass, chapter, "getAbsoluteURL"));
        }
        stages.put("toc", new JSONObject()
            .put("pages", replay.requestsInStage("tableOfContents"))
            .put("chapters", chapterArray)
            .put("chaptersAbsolute", chapterAbsolute));
        if (chapters.isEmpty()) {
            throw new IllegalStateException("table of contents returned no chapter");
        }

        stage.set("content");
        log("stage content");
        // needSave=false: a synthetic corpus has no row in the frozen application's
        // database, so saving the chapter is a storage side effect outside the
        // compared surface (recorded in the golden's manifest).
        Object text = runSuspend(loader, continuation -> call(webBookClass, webBook,
            "getContentAwait", 6,
            new Object[]{source, book, chapters.get(0), null, Boolean.FALSE}, continuation));
        log("stage content returned");
        stages.put("content", new JSONObject()
            .put("chapter", str(chapterClass, chapters.get(0), "getTitle"))
            .put("pages", replay.requestsInStage("content"))
            .put("text", text == null ? "" : text.toString()));

        JSONArray withCookie = new JSONArray();
        JSONArray withoutCookie = new JSONArray();
        for (int index = 0; index < requests.length(); index++) {
            JSONObject request = requests.getJSONObject(index);
            String cookie = request.getJSONObject("headers").optString("cookie", "");
            (cookie.isEmpty() ? withoutCookie : withCookie)
                .put(request.getString("method") + " " + request.getString("path"));
        }
        state.put("requestsWithCookie", withCookie)
            .put("requestsWithoutCookie", withoutCookie)
            .put("chapterCount", chapters.size())
            .put("contentLength", text == null ? 0 : text.toString().length());
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
                        return "slice-oracle-block";
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
            // mangled with a hash suffix (kotlin.Result -> getChapterListAwait-IoAF18A),
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
        Log.i("SliceOracle", "frozen entry " + target.getName() + " on " + target.getDeclaringClass().getName());
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
     * {@code Result} is an inline value class and {@code getOrNull} is an inlined
     * extension, so neither a class member nor a callable method exists on the
     * boxed instance. The boxed payload is taken from the synthetic
     * {@code unbox-impl} method, falling back to the private {@code value} field;
     * a failure payload surfaces the frozen exception instead of hiding it.
     */
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
                if (exception instanceof Throwable) throw new IllegalStateException((Throwable) exception);
            }
        }
        throw new IllegalStateException("table of contents result is "
            + result.getClass().getName() + " payload=" + payload);
    }

    private static String str(Class<?> owner, Object instance, String getter) {
        try {
            Object value = owner.getMethod(getter).invoke(instance);
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
     * The matching rule is {@code tool/first_slice/runner.dart}'s: a response that
     * declares a {@code query} wins over one that does not, and a declared query
     * must match the decoded request query exactly.
     */
    private static final class SliceReplay {
        private final JSONObject corpus;
        private final JSONArray requests;
        private final JSONArray unmatched;
        private final JSONArray serverErrors;
        private final JSONArray stageTrace;
        private final AtomicReference<String> stage;
        private final ExecutorService clients = Executors.newFixedThreadPool(4);
        private final java.util.Set<Socket> openSockets = new java.util.HashSet<>();
        private ServerSocket server;
        private Thread worker;
        private final java.util.concurrent.atomic.AtomicInteger open =
            new java.util.concurrent.atomic.AtomicInteger();

        SliceReplay(JSONObject corpus, JSONArray requests, JSONArray unmatched,
                JSONArray serverErrors, JSONArray stageTrace, AtomicReference<String> stage) {
            this.corpus = corpus;
            this.requests = requests;
            this.unmatched = unmatched;
            this.serverErrors = serverErrors;
            this.stageTrace = stageTrace;
            this.stage = stage;
        }

        void start() throws IOException {
            server = new ServerSocket(18731, 16, InetAddress.getByName("127.0.0.1"));
            worker = new Thread(this::accept, "slice-oracle-replay");
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

        int requestsInStage(String name) {
            int count = 0;
            for (int index = 0; index < stageTrace.length(); index++) {
                JSONObject entry = stageTrace.optJSONObject(index);
                if (entry != null && name.equals(entry.optString("stage"))) count++;
            }
            return count;
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
                        .put("path", "http://127.0.0.1:18731" + path
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
            for (JSONObject candidate : candidates) {
                if (candidate.isNull("query")) return candidate;
            }
            return null;
        }
    }
}
