package io.liber.oracle.nested;

import android.app.Instrumentation;
import android.os.Bundle;
import android.os.Build;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.lang.reflect.*;
import java.util.*;

/** Calls the installed, hash-pinned APK. No Legado production class is rebuilt. */
public final class NestedOracle extends Instrumentation {
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    @Override public void onStart() {
        Bundle status = new Bundle();
        try (Replay replay = new Replay()) {
            String fixture;
            try (InputStream input = getContext().getAssets().open("fixtures.json")) {
                fixture = new String(input.readAllBytes(), StandardCharsets.UTF_8);
            }
            JSONObject corpus = new JSONObject(fixture);
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
            File output = new File(getTargetContext().getExternalFilesDir(null), "nested-oracle.json");
            try (FileOutputStream stream = new FileOutputStream(output)) {
                stream.write(report.toString(2).getBytes(StandardCharsets.UTF_8));
            }
            status.putString("stream", "Nested oracle recorded " + observations.length() + " observations\n");
            finish(-1, status);
        } catch (Throwable error) {
            status.putString("stream", error.toString() + "\n");
            finish(1, status);
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
