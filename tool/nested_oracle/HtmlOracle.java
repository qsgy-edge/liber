package io.liber.oracle.nested;

import android.app.Instrumentation;
import android.os.Build;
import android.os.Bundle;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/**
 * The frozen side of the HTML extraction corpus: loads
 * {@code io.legado.app.model.analyzeRule.AnalyzeRule} from the installed,
 * hash-pinned {@code io.legado.app.debug}, calls
 * {@code setContent(html, baseUrl)} and then {@code getString(rule)} or
 * {@code getStringList(rule)} as each case declares (the original cases use
 * {@code getString}). No Legado class is rebuilt; the entry
 * points are reached by reflection.
 *
 * <p>The base URL handed to {@code setContent} is the corpus' {@code baseUrl}:
 * a {@code {{baseUrl}}} rule field only carries the device-side value the
 * corpus expects when that argument is the committed one (#51).
 *
 * <p>The report's shape follows {@code NestedOracle}/{@code StateOracle} so
 * {@code tool/html_adapter_gate.dart} can read it against the Liber-side
 * observation. It also binds every observation set to the raw bytes of the
 * selected {@code html-fixtures.json} asset: the build may copy either the
 * original corpus or the independently selected list corpus under that asset
 * name, so the report carries the asset's actual byte count and SHA-256 (and
 * its declared fixture id/version when present), never a hash copied from the
 * corpus JSON.
 */
public final class HtmlOracle extends Instrumentation {
    /** Fallback for a corpus without a {@code baseUrl}; relative-URL base only. */
    private static final String DEFAULT_BASE_URL = "http://localhost/";

    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }

    @Override public void onStart() {
        Bundle status = new Bundle();
        try {
            String fixture;
            byte[] fixtureBytes;
            try (InputStream input = getContext().getAssets().open("html-fixtures.json")) {
                fixtureBytes = input.readAllBytes();
                fixture = new String(fixtureBytes, StandardCharsets.UTF_8);
            }
            JSONObject corpus = new JSONObject(fixture);
            JSONObject documents = corpus.getJSONObject("documents");
            JSONArray cases = corpus.getJSONArray("cases");
            String baseUrl = corpus.optString("baseUrl", DEFAULT_BASE_URL);
            ClassLoader loader = getTargetContext().getClassLoader();
            Class<?> ruleClass = loader.loadClass("io.legado.app.model.analyzeRule.AnalyzeRule");
            Constructor<?> ctor = null;
            for (Constructor<?> candidate : ruleClass.getConstructors()) {
                if (ctor == null || candidate.getParameterCount() < ctor.getParameterCount()) ctor = candidate;
            }
            if (ctor == null) throw new IllegalStateException("Frozen AnalyzeRule constructor absent");
            Method setContent = ruleClass.getMethod("setContent", Object.class, String.class);
            Method getString = ruleClass.getMethod("getString", String.class);
            Method getStringUrl = ruleClass.getMethod("getString", String.class, Object.class, boolean.class);
            Method getStringList = ruleClass.getMethod("getStringList", String.class);
            Method getStringListUrl = ruleClass.getMethod("getStringList", String.class, Object.class, boolean.class);
            JSONArray observations = new JSONArray();
            for (int i = 0; i < cases.length(); i++) {
                JSONObject entry = cases.getJSONObject(i);
                JSONObject result = new JSONObject().put("id", entry.getString("id"));
                try {
                    Object rule = ctor.newInstance(new Object[ctor.getParameterCount()]);
                    setContent.invoke(rule, documents.getString(entry.getString("document")), baseUrl);
                    String method = entry.optString("method", "getString");
                    String text = entry.getString("rule");
                    Object value;
                    if ("getStringUrl".equals(method)) {
                        value = getStringUrl.invoke(rule, text, null, true);
                    } else if ("getStringListUrl".equals(method)) {
                        value = getStringListUrl.invoke(rule, text, null, true);
                    } else if ("getStringList".equals(method)) {
                        value = getStringList.invoke(rule, text);
                    } else if ("getString".equals(method)) {
                        value = getString.invoke(rule, text);
                    } else {
                        throw new IllegalArgumentException("Unknown oracle method: " + method);
                    }
                    result.put("value", value instanceof java.util.Collection<?>
                        ? new JSONArray((java.util.Collection<?>) value)
                        : value == null ? JSONObject.NULL : value);
                } catch (InvocationTargetException error) {
                    Throwable cause = error.getCause();
                    result.put("error", (cause == null ? error : cause).getClass().getName());
                }
                observations.put(result);
            }
            JSONObject corpusIdentity = new JSONObject()
                .put("asset", "html-fixtures.json")
                .put("bytes", fixtureBytes.length)
                .put("sha256", sha256(fixtureBytes));
            if (corpus.has("fixtureId")) corpusIdentity.put("fixtureId", corpus.getString("fixtureId"));
            if (corpus.has("corpusVersion")) corpusIdentity.put("corpusVersion", corpus.getInt("corpusVersion"));
            if (corpus.has("schemaVersion")) corpusIdentity.put("schemaVersion", corpus.getInt("schemaVersion"));
            JSONObject report = new JSONObject().put("baselineCommit", corpus.getString("baselineCommit"))
                .put("fingerprint", Build.FINGERPRINT).put("entryPoint", corpus.getString("entryPoint"))
                .put("corpus", corpusIdentity)
                .put("observations", observations);
            File output = new File(getTargetContext().getExternalFilesDir(null), "html-oracle.json");
            try (FileOutputStream stream = new FileOutputStream(output)) {
                stream.write(report.toString(2).getBytes(StandardCharsets.UTF_8));
            }
            status.putString("stream", "Html oracle recorded " + observations.length() + " observations\n");
            finish(-1, status);
        } catch (Throwable error) {
            status.putString("stream", error.toString() + "\n");
            finish(1, status);
        }
    }

    /** The selected asset's actual bytes, hex-encoded for the report binding. */
    private static String sha256(byte[] bytes) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
        StringBuilder hex = new StringBuilder(digest.length * 2);
        for (byte value : digest) {
            hex.append(Character.forDigit((value >> 4) & 0xf, 16));
            hex.append(Character.forDigit(value & 0xf, 16));
        }
        return hex.toString();
    }
}
