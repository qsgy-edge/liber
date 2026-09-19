package io.liber.oracle.nested;

import android.app.Instrumentation;
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
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
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
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The frozen side of the request-semantics corpus: drives
 * {@code io.legado.app.model.analyzeRule.AnalyzeUrl}'s suspend
 * {@code getStrResponseAwait} through reflection inside the installed,
 * hash-pinned {@code io.legado.app.debug} process, and serves
 * {@code tool/nested_oracle/request-fixtures.json} from an in-process replay
 * server on port 18731. No Legado class is rebuilt and no host-side server is
 * used: the device process is both client and server, so the requests the
 * server receives are the row's evidence.
 *
 * <p>The work is posted to the main looper because the target application -- and
 * with it OkHttp's client singletons -- is created after {@link #onCreate}. The
 * rows then run on their own thread, because they are driven with
 * {@code kotlinx.coroutines.runBlocking}.
 *
 * <p>The server binds the wildcard address rather than {@code 127.0.0.1}
 * itself: the corpus uses the IPv4 loopback literals {@code 127.0.0.2} and
 * {@code 127.0.0.3} so that the cross-origin row has two origins and the rows'
 * frozen cookie lookups (keyed by the URL host) cannot see a cookie an earlier
 * corpus stored for {@code 127.0.0.1}. One wildcard socket serves both hosts.
 */
public final class RequestOracle extends Instrumentation {

    private static final int PORT = 18731;

    private final JSONArray serverErrors = new JSONArray();
    private final AtomicReference<String> stage = new AtomicReference<>("setup");
    private final java.util.concurrent.atomic.AtomicBoolean finished =
        new java.util.concurrent.atomic.AtomicBoolean();

    private JSONObject corpus;
    private Replay replay;

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        log("onCreate");
        new Handler(Looper.getMainLooper()).post(() -> {
            log("main looper reached; starting the worker thread");
            new Thread(this::run, "request-oracle").start();
        });
        startWatchdog();
    }

    /** An instrumentation that never finishes reports nothing on the host. */
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
                status.putString("stream", "Request oracle timed out in stage " + stage.get()
                    + " with " + replay.requests.length() + " requests\n");
                finish(1, status);
            }
        }, "request-oracle-watchdog");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    private void log(String message) {
        Log.i("RequestOracle", message);
    }

    private void run() {
        Bundle status = new Bundle();
        try {
            corpus = new JSONObject(readAsset("request-fixtures.json"));
            log("corpus loaded: " + corpus.getString("fixtureId"));
            String failure = null;
            JSONArray rows = new JSONArray();
            JSONObject cleanup = new JSONObject();
            replay = new Replay(corpus, serverErrors);
            replay.start();
            log("replay server bound to the wildcard address on port " + PORT);
            try {
                drive(rows);
            } catch (Throwable error) {
                failure = describe(error);
                log("drive failed: " + failure);
            }
            JSONObject report = new JSONObject()
                .put("fixtureId", corpus.getString("fixtureId"))
                .put("corpusVersion", corpus.getInt("corpusVersion"))
                .put("baselineCommit", corpus.getString("baselineCommit"))
                .put("entryPoint", corpus.getString("entryPoint"))
                .put("platform", "android")
                .put("fingerprint", Build.FINGERPRINT)
                .put("recordedAt", timestamp())
                .put("rows", rows)
                .put("requests", replay.requests)
                .put("serverErrors", serverErrors)
                .put("cleanup", cleanup)
                .put("analysisFailure", failure == null ? JSONObject.NULL : failure);
            File output = new File(getTargetContext().getExternalFilesDir(null), "request-oracle.json");
            // The report is written before the server is torn down: the run's
            // evidence must survive a host that freezes this process a few
            // seconds in (MIUI does; see the golden's manifest).
            writeReport(output, report);
            log("report written; failure=" + failure);
            stage.set("cleanup");
            cleanup.put("openConnections", replay.openConnections());
            try {
                replay.close();
                cleanup.put("serverClosed", true);
            } catch (Throwable error) {
                cleanup.put("serverClosed", false);
                log("cleanup failed: " + describe(error));
            }
            // Second write: the first captured cleanup as {}, which reads as an
            // affirmative clean.
            writeReport(output, report);
            log("report rewritten with cleanup=" + cleanup);
            status.putString("stream", failure == null
                ? "Request oracle recorded " + rows.length() + " rows and "
                    + replay.requests.length() + " requests\n"
                : "Request oracle failed: " + failure + "\n");
            finished.set(true);
            finish(failure == null ? -1 : 1, status);
        } catch (Throwable error) {
            status.putString("stream", "Request oracle harness error: " + describe(error) + "\n");
            log("harness error: " + describe(error));
            finished.set(true);
            finish(1, status);
        }
    }

    /** One row per corpus row, in the corpus' order. */
    private void drive(JSONArray rows) throws Exception {
        ClassLoader loader = getTargetContext().getClassLoader();
        Class<?> urlClass = loader.loadClass("io.legado.app.model.analyzeRule.AnalyzeUrl");
        Object context = loader.loadClass("kotlin.coroutines.EmptyCoroutineContext")
            .getField("INSTANCE").get(null);
        Constructor<?> constructor = null;
        for (Constructor<?> candidate : urlClass.getConstructors()) {
            if (candidate.getParameterCount() != 14) continue;
            Class<?>[] types = candidate.getParameterTypes();
            if (types[0] == String.class && types[13] == Boolean.TYPE) constructor = candidate;
        }
        if (constructor == null) throw new IllegalStateException("frozen AnalyzeUrl constructor absent");
        log("frozen AnalyzeUrl constructor: " + constructor);

        String origin = corpus.getString("origin");
        String otherOrigin = corpus.getString("otherOrigin");
        JSONArray declared = corpus.getJSONArray("rows");
        for (int index = 0; index < declared.length(); index++) {
            JSONObject row = declared.getJSONObject(index);
            String id = row.getString("id");
            JSONObject request = row.getJSONObject("request");
            String rule = substitute(request.getString("rule"), origin, otherOrigin);
            String baseUrl = substitute(request.getString("baseUrl"), origin, otherOrigin);
            Object key = request.isNull("key") ? null : request.getString("key");
            Object page = request.isNull("page") ? null : Integer.valueOf(request.getInt("page"));
            Map<String, String> headers = null;
            JSONObject declaredHeaders = request.optJSONObject("headers");
            if (declaredHeaders != null) {
                headers = new LinkedHashMap<>();
                Iterator<String> names = declaredHeaders.keys();
                while (names.hasNext()) {
                    String name = names.next();
                    headers.put(name, declaredHeaders.getString(name));
                }
            }
            stage.set(id);
            int before = replay.requests.length();
            JSONObject observation = new JSONObject().put("id", id);
            try {
                Object analyzeUrl = constructor.newInstance(
                    rule, key, page, null, null, baseUrl, null, null, null,
                    null, null, context, headers, Boolean.TRUE);
                Object response = runSuspend(loader, continuation -> {
                    // getStrResponseAwait(jsStr, sourceRegex, useWebView, continuation):
                    // the WebView arguments stay at their defaults, and useWebView is
                    // false for every row in this corpus.
                    Method target = null;
                    for (Method candidate : urlClass.getMethods()) {
                        if (!candidate.getName().equals("getStrResponseAwait")) continue;
                        Class<?>[] types = candidate.getParameterTypes();
                        if (types.length != 4) continue;
                        if (!types[3].getName().equals("kotlin.coroutines.Continuation")) continue;
                        target = candidate;
                    }
                    if (target == null) throw new IllegalStateException("frozen getStrResponseAwait absent");
                    try {
                        return target.invoke(analyzeUrl, null, null, Boolean.TRUE, continuation);
                    } catch (InvocationTargetException error) {
                        throw error.getCause();
                    }
                });
                observation.put("outcome", "ok")
                    .put("status", rawStatus(response))
                    .put("finalUrl", rawUrl(response))
                    .put("body", rawBody(response));
            } catch (Throwable error) {
                observation.put("outcome", "error").put("error", describe(error));
            }
            observation.put("requests", slice(before));
            rows.put(observation);
            log("row " + id + ": " + observation.optString("outcome")
                + " requests=" + observation.getJSONArray("requests").length());
        }
    }

    private JSONArray slice(int from) {
        JSONArray slice = new JSONArray();
        synchronized (replay.requests) {
            for (int index = from; index < replay.requests.length(); index++) {
                slice.put(replay.requests.opt(index));
            }
        }
        return slice;
    }

    /** Reads one field of the frozen {@code StrResponse} without linking it. */
    private static Object responseField(Object response, String name) throws Exception {
        for (Method candidate : response.getClass().getMethods()) {
            if (!candidate.getName().equals(name) || candidate.getParameterCount() != 0) continue;
            return candidate.invoke(response);
        }
        throw new IllegalStateException("frozen StrResponse member absent: " + name);
    }

    private static Object rawField(Object response, String name) throws Exception {
        Object raw = responseField(response, "getRaw");
        for (Method candidate : raw.getClass().getMethods()) {
            if (!candidate.getName().equals(name) || candidate.getParameterCount() != 0) continue;
            return candidate.invoke(raw);
        }
        throw new IllegalStateException("frozen okhttp Response member absent: " + name);
    }

    private static int rawStatus(Object response) {
        try {
            return ((Number) rawField(response, "code")).intValue();
        } catch (Exception error) {
            return -1;
        }
    }

    private static String rawUrl(Object response) {
        try {
            Object request = rawField(response, "request");
            Object url = request.getClass().getMethod("url").invoke(request);
            return url.toString();
        } catch (Exception error) {
            return "";
        }
    }

    private static String rawBody(Object response) {
        try {
            Object body = responseField(response, "getBody");
            return body == null ? "" : body.toString();
        } catch (Exception error) {
            return "";
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
                        return call.run(args[1]);
                    case "toString":
                        return "request-oracle-block";
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

    private static String substitute(String text, String origin, String otherOrigin) {
        return text.replace("$OTHER_ORIGIN", otherOrigin).replace("$ORIGIN", origin);
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

    private static void writeReport(File output, JSONObject report)
            throws IOException, JSONException {
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
        StringBuilder text = new StringBuilder(error.getClass().getName()
            + (error.getMessage() == null ? "" : ": " + error.getMessage()));
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
     * The corpus' replay server: every response comes from the corpus and an
     * undeclared request is answered 404 and recorded. Responses are matched on
     * method and path; the corpus' paths are unique per row, so the query text
     * is recorded as evidence rather than used for matching.
     */
    private static final class Replay {
        private final JSONObject corpus;
        private final JSONArray requests = new JSONArray();
        private final JSONArray serverErrors;
        private final ExecutorService clients = Executors.newFixedThreadPool(4);
        private final java.util.Set<Socket> openSockets = new java.util.HashSet<>();
        private final AtomicInteger open = new AtomicInteger();
        private ServerSocket server;
        private Thread worker;

        Replay(JSONObject corpus, JSONArray serverErrors) {
            this.corpus = corpus;
            this.serverErrors = serverErrors;
        }

        void start() throws IOException {
            // Wildcard bind: one socket serves 127.0.0.2 and 127.0.0.3.
            server = new ServerSocket(PORT, 16);
            worker = new Thread(this::accept, "request-oracle-replay");
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
            // A keep-alive connection is parked in readLine and an interrupt does
            // not close a socket read, so the sockets are closed rather than waited out.
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
                JSONObject observed = new JSONObject()
                    .put("method", method)
                    .put("path", path)
                    .put("rawQuery", rawQuery)
                    .put("query", new JSONObject(decodeQuery(rawQuery)))
                    .put("headers", new JSONObject(headers))
                    .put("body", body);
                synchronized (requests) {
                    requests.put(observed);
                }
                OutputStream output = socket.getOutputStream();
                JSONObject declared = match(method, path);
                if (declared == null) {
                    byte[] text = "undeclared replay request".getBytes(StandardCharsets.UTF_8);
                    output.write(("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
                        + "Content-Length: " + text.length + "\r\n\r\n")
                        .getBytes(StandardCharsets.US_ASCII));
                    output.write(text);
                } else {
                    // The declared strings carry the corpus' origin tokens, so a
                    // Location header and a body are both substituted here: the
                    // header is text, the body is this file's UTF-8 bytes.
                    byte[] bytes = substituted(declared.optString("body", ""))
                        .getBytes(StandardCharsets.UTF_8);
                    StringBuilder head = new StringBuilder();
                    head.append("HTTP/1.1 ").append(declared.optInt("status", 200)).append(" OK\r\n");
                    JSONObject declaredHeaders = declared.optJSONObject("headers");
                    if (declaredHeaders != null) {
                        Iterator<String> names = declaredHeaders.keys();
                        while (names.hasNext()) {
                            String name = names.next();
                            head.append(name).append(": ")
                                .append(substituted(declaredHeaders.optString(name))).append("\r\n");
                        }
                    }
                    head.append("Content-Length: ").append(bytes.length).append("\r\n\r\n");
                    output.write(head.toString().getBytes(StandardCharsets.US_ASCII));
                    output.write(bytes);
                }
                output.flush();
            }
        }

        private String substituted(String text) {
            return substitute(text, corpus.optString("origin"), corpus.optString("otherOrigin"));
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

        private JSONObject match(String method, String path) {
            JSONArray responses = corpus.optJSONArray("responses");
            if (responses == null) return null;
            for (int index = 0; index < responses.length(); index++) {
                JSONObject response = responses.optJSONObject(index);
                if (response == null) continue;
                if (!method.equals(response.optString("method"))) continue;
                if (!path.equals(response.optString("path"))) continue;
                return response;
            }
            return null;
        }
    }
}
