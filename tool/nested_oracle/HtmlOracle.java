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

/**
 * The frozen side of the HTML extraction corpus: loads
 * {@code io.legado.app.model.analyzeRule.AnalyzeRule} from the installed,
 * hash-pinned {@code io.legado.app.debug}, calls
 * {@code setContent(html, baseUrl)} and then {@code getString(rule)} for every
 * case of {@code tool/html_oracle/fixtures.json} (bundled in the harness assets),
 * and writes the report the corpus names. No Legado class is rebuilt; the entry
 * points are reached by reflection.
 *
 * <p>The base URL handed to {@code setContent} is the corpus' {@code baseUrl}:
 * a {@code {{baseUrl}}} rule field only carries the device-side value the
 * corpus expects when that argument is the committed one (#51).
 *
 * <p>The report's shape follows {@code NestedOracle}/{@code StateOracle} so
 * {@code tool/html_adapter_gate.dart} can read it against the Liber-side
 * observation.
 */
public final class HtmlOracle extends Instrumentation {
    /** Fallback for a corpus without a {@code baseUrl}; relative-URL base only. */
    private static final String DEFAULT_BASE_URL = "http://localhost/";

    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }

    @Override public void onStart() {
        Bundle status = new Bundle();
        try {
            String fixture;
            try (InputStream input = getContext().getAssets().open("html-fixtures.json")) {
                fixture = new String(input.readAllBytes(), StandardCharsets.UTF_8);
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
            JSONArray observations = new JSONArray();
            for (int i = 0; i < cases.length(); i++) {
                JSONObject entry = cases.getJSONObject(i);
                JSONObject result = new JSONObject().put("id", entry.getString("id"));
                try {
                    Object rule = ctor.newInstance(new Object[ctor.getParameterCount()]);
                    setContent.invoke(rule, documents.getString(entry.getString("document")), baseUrl);
                    result.put("value", getString.invoke(rule, entry.getString("rule")));
                } catch (InvocationTargetException error) {
                    Throwable cause = error.getCause();
                    result.put("error", (cause == null ? error : cause).getClass().getName());
                }
                observations.put(result);
            }
            JSONObject report = new JSONObject().put("baselineCommit", corpus.getString("baselineCommit"))
                .put("fingerprint", Build.FINGERPRINT).put("entryPoint", corpus.getString("entryPoint"))
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
}
