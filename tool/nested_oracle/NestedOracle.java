package io.liber.oracle.nested;

import android.app.Instrumentation;
import android.os.Bundle;
import android.os.Build;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.lang.reflect.*;
import java.util.*;

/** Calls the installed, hash-pinned APK. No Legado production class is rebuilt. */
public final class NestedOracle extends Instrumentation {
    private Bundle arguments;
    @Override public void onCreate(Bundle args) { arguments = args; super.onCreate(args); start(); }
    @Override public void onStart() {
        Bundle status = new Bundle();
        try (Replay replay = new Replay()) {
            // The default run is unchanged. An explicit `-e corpus jslib` selects
            // the local jsLib shared-scope corpus; nothing else may change it.
            boolean jsLib = "jslib".equals(
                arguments == null ? null : arguments.getString("corpus"));
            String asset = jsLib ? "jslib-fixtures.json" : "fixtures.json";
            byte[] fixtureBytes;
            try (InputStream input = getContext().getAssets().open(asset)) {
                fixtureBytes = input.readAllBytes();
            }
            String fixture = new String(fixtureBytes, StandardCharsets.UTF_8);
            JSONObject corpus = new JSONObject(fixture);
            // The jsLib capture is only labelled frozen after the installed
            // target's own package and APK bytes are measured and verified
            // against the pin the corpus carries. Nothing is written if either
            // disagrees, so a same-package substitute build cannot be captured
            // under the frozen label.
            String targetPackage = null;
            String targetApkPath = null;
            String targetApkSha256 = null;
            if (jsLib) {
                JSONObject target = corpus.getJSONObject("target");
                targetPackage = getTargetContext().getPackageName();
                targetApkPath = getTargetContext().getApplicationInfo().sourceDir;
                targetApkSha256 = sha256(readAll(new File(targetApkPath)));
                if (!targetPackage.equals(target.getString("package"))) {
                    throw new IllegalStateException(
                        "Frozen target package mismatch: measured " + targetPackage
                            + ", pin " + target.getString("package"));
                }
                if (!targetApkSha256.equals(target.getString("apkSha256"))) {
                    throw new IllegalStateException(
                        "Frozen target APK mismatch: measured " + targetApkSha256
                            + ", pin " + target.getString("apkSha256"));
                }
            }
            ClassLoader loader = getTargetContext().getClassLoader();
            Class<?> sourceClass = loader.loadClass("io.legado.app.data.entities.BookSource");
            Class<?> urlClass = loader.loadClass("io.legado.app.model.analyzeRule.AnalyzeUrl");
            Object context = loader.loadClass("kotlin.coroutines.EmptyCoroutineContext").getField("INSTANCE").get(null);
            Constructor<?> ctor = null;
            for (Constructor<?> candidate : urlClass.getConstructors()) {
                if (candidate.getParameterCount() == 14) ctor = candidate;
            }
            if (ctor == null) throw new IllegalStateException("Frozen AnalyzeUrl constructor absent");
            Method eval = urlClass.getMethod("evalJS", String.class, Object.class);
            Map<String,Object> sources = new HashMap<>();
            JSONArray observations = new JSONArray();
            JSONArray steps = corpus.getJSONArray("steps");
            for (int i = 0; i < steps.length(); i++) {
                JSONObject step = steps.getJSONObject(i);
                String key = step.optString("sourceKey", "first");
                Object source = sources.get(key);
                if (source == null) {
                    source = sourceClass.getConstructor().newInstance();
                    sourceClass.getMethod("setBookSourceUrl", String.class).invoke(source, replay.origin + "/source/" + key);
                    sourceClass.getMethod("setJsLib", String.class).invoke(source, corpus.getString("jsLib"));
                    sources.put(key, source);
                }
                Object url = ctor.newInstance(replay.origin + "/", "outer-key", Integer.valueOf(7), null, null, "", source, null, null, null, null, context, null, Boolean.TRUE);
                JSONObject result = new JSONObject().put("id", step.getString("id"));
                try {
                    Object value = eval.invoke(url, step.getString("script").replace("$ORIGIN", replay.origin), null);
                    result.put("value", value == null ? JSONObject.NULL : value.toString());
                } catch (InvocationTargetException error) {
                    result.put("error", error.getCause().getClass().getName());
                }
                observations.put(result);
            }
            JSONObject report = new JSONObject().put("baselineCommit", corpus.getString("baselineCommit"))
                .put("fingerprint", Build.FINGERPRINT).put("entryPoint", corpus.getString("entryPoint"))
                .put("observations", observations).put("requests", replay.requests);
            if (jsLib) {
                // The comparator refuses to compare without this identity, the
                // corpus hash and the measured frozen-capture provenance block.
                report.put("fixtureId", corpus.getString("fixtureId"));
                report.put("corpusVersion", corpus.getInt("corpusVersion"));
                report.put("corpusSha256", sha256Lf(fixtureBytes));
                JSONObject target = corpus.getJSONObject("target");
                report.put("provenance", new JSONObject()
                    .put("kind", "frozen-device-capture")
                    .put("deviceFingerprint", Build.FINGERPRINT)
                    .put("capturedAt", new java.text.SimpleDateFormat(
                        "yyyy-MM-dd'T'HH:mm:ssXXX", java.util.Locale.US).format(new Date()))
                    .put("entryPoint", corpus.getString("entryPoint"))
                    .put("baselineCommit", corpus.getString("baselineCommit"))
                    .put("targetPackage", targetPackage)
                    .put("targetApkPath", targetApkPath)
                    .put("targetApkSha256", targetApkSha256)
                    .put("targetPin", new JSONObject()
                        .put("package", target.getString("package"))
                        .put("apkSha256", target.getString("apkSha256"))
                        .put("manifest", target.optString("manifest", ""))));
            }
            File output = new File(getTargetContext().getExternalFilesDir(null),
                jsLib ? "jslib-oracle.json" : "nested-oracle.json");
            try (FileOutputStream stream = new FileOutputStream(output)) {
                stream.write(report.toString(2).getBytes(StandardCharsets.UTF_8));
            }
            status.putString("stream", (jsLib ? "jsLib oracle" : "Nested oracle")
                + " recorded " + observations.length() + " observations\n");
            finish(-1, status);
        } catch (Throwable error) {
            status.putString("stream", error.toString() + "\n");
            finish(1, status);
        }
    }

    /** SHA-256 of the corpus bytes with CRLF normalized to LF, so one pin means
     *  the same corpus on a Windows and an LF checkout. */
    static String sha256Lf(byte[] bytes) throws Exception {
        String text = new String(bytes, StandardCharsets.UTF_8).replace("\r\n", "\n");
        return sha256(text.getBytes(StandardCharsets.UTF_8));
    }

    /** Raw SHA-256 of the installed target APK bytes. */
    static String sha256(byte[] bytes) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
        StringBuilder hex = new StringBuilder();
        for (byte value : digest) hex.append(String.format("%02x", value));
        return hex.toString();
    }

    static byte[] readAll(File file) throws Exception {
        try (InputStream input = new FileInputStream(file)) {
            return input.readAllBytes();
        }
    }

    static final class Replay implements AutoCloseable {
        final ServerSocket server = new ServerSocket(18763, 16, InetAddress.getByName("127.0.0.1"));
        final String origin = "http://127.0.0.1:18763";
        final JSONArray requests = new JSONArray();
        final Thread worker;
        Replay() throws IOException {
            worker = new Thread(() -> {
                while (!server.isClosed()) {
                    try (Socket client = server.accept()) {
                        client.setSoTimeout(10000);
                        BufferedReader input = new BufferedReader(new InputStreamReader(client.getInputStream(), StandardCharsets.UTF_8));
                        String line = input.readLine();
                        if (line == null) continue;
                        String[] request = line.split(" ", 3);
                        String rawPath = request[1];
                        synchronized (requests) { requests.put(request[0] + " " + rawPath); }
                        while ((line = input.readLine()) != null && !line.isEmpty()) { }
                        String path = URLDecoder.decode(rawPath, "UTF-8");
                        byte[] body = (path.startsWith("/value/") ? path.substring(7) : "").getBytes(StandardCharsets.UTF_8);
                        OutputStream output = client.getOutputStream();
                        output.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: " + body.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                        output.write(body);
                        output.flush();
                    } catch (IOException error) {
                        if (!server.isClosed()) synchronized (requests) { requests.put("SERVER_ERROR " + error.getClass().getName()); }
                    }
                }
            }, "nested-oracle-replay");
            worker.start();
        }
        public void close() throws Exception { server.close(); worker.join(1000); if (worker.isAlive()) throw new IllegalStateException("Replay worker did not stop"); }
    }
}
