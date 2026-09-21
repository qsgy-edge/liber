package io.liber.oracle.replacejs;

import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.SharedPreferences;
import android.database.DatabaseErrorHandler;
import android.database.sqlite.SQLiteDatabase;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.lang.reflect.Array;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** Drives the installed frozen APK's real `@js:` replacement path (ticket #49).
 *
 * Every row goes through the frozen `ContentProcessor.getContent` and
 * `BookChapter.getDisplayTitle`, which reach `CharSequence.replace(regex,
 * replacement, timeout)` in `RegexExtensions.kt` — the branch that evaluates a
 * `@js:` replacement with the complete match bound as `result` and inserts the
 * returned value through `Matcher.quoteReplacement`. No Legado class is copied,
 * recompiled or translated: only the application lifecycle and the storage
 * context are supplied by the harness, so the real Room builder, DAO, entities,
 * processor, regex engine and Rhino runtime all execute.
 *
 * This is a disposable, package-isolated harness (`io.liber.oracle.replacejs`).
 * It is separate from `tool/replace_rule_oracle/` and never reads or rewrites
 * its corpus, golden or comparison.
 */
public final class ReplaceJsOracle extends Instrumentation {
    private ScratchContext scratch;
    private Object database;
    private ClassLoader loader;

    @Override public Application newApplication(ClassLoader cl, String name, Context context)
            throws InstantiationException, IllegalAccessException, ClassNotFoundException {
        scratch = new ScratchContext(context);
        return super.newApplication(cl, Application.class.getName(), scratch);
    }

    @Override public void onCreate(Bundle args) {
        super.onCreate(args);
        new Handler(Looper.getMainLooper()).post(() ->
            new Thread(this::run, "replace-js-oracle").start());
    }

    private void run() {
        JSONObject report = new JSONObject();
        Bundle status = new Bundle();
        boolean ok = false;
        try {
            loader = getTargetContext().getClassLoader();
            byte[] bytes;
            try (InputStream input = getContext().getAssets().open("replace-js-fixtures.json")) {
                ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                byte[] chunk = new byte[8192];
                int count;
                while ((count = input.read(chunk)) != -1) buffer.write(chunk, 0, count);
                bytes = buffer.toByteArray();
            }
            JSONObject corpus = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
            report.put("fixtureId", corpus.getString("fixtureId"))
                .put("corpusVersion", corpus.getInt("corpusVersion"))
                .put("baselineCommit", corpus.getString("baselineCommit"))
                .put("fixtureSha256", hash(bytes))
                .put("fingerprint", Build.FINGERPRINT)
                .put("recordedAtEpochMillis", System.currentTimeMillis())
                .put("boundary", corpus.getString("comparisonBoundary"));
            // splitties is initialized by the installed APK's provider. Fail closed
            // before opening Room or settings if it escaped the scratch Application.
            Context app = (Context) loader.loadClass("splitties.init.AppCtxKt")
                .getMethod("getAppCtx").invoke(null);
            if (!app.getFilesDir().equals(scratch.getFilesDir())) {
                throw new IllegalStateException("appCtx escaped scratch files directory");
            }
            if (!app.getDatabasePath("legado.db").equals(scratch.getDatabasePath("legado.db"))) {
                throw new IllegalStateException("appCtx escaped scratch database directory");
            }
            report.put("isolation", new JSONObject()
                .put("application", app.getClass().getName())
                .put("files", app.getFilesDir().toString())
                .put("database", app.getDatabasePath("legado.db").toString())
                .put("preferencesPrefix", ScratchContext.PREFIX)
                .put("frozenAppOnCreate", "not-run: unrelated background maintenance"));
            database = loader.loadClass("io.legado.app.data.AppDatabaseKt")
                .getMethod("getAppDb").invoke(null);
            Object dao = call(database, "getReplaceRuleDao");
            Object config = singleton("io.legado.app.help.config.AppConfig");
            Object readConfig = singleton("io.legado.app.help.config.ReadBookConfig");
            call(readConfig, "setParagraphIndent", "　　");
            report.put("paragraphIndent", call(readConfig, "getParagraphIndent"));
            JSONArray rows = new JSONArray();
            report.put("rows", rows);
            JSONArray cases = corpus.getJSONArray("cases");
            for (int i = 0; i < cases.length(); i++) {
                JSONObject row = cases.getJSONObject(i);
                JSONObject observed = new JSONObject().put("id", row.getString("id"));
                rows.put(observed);
                long start = System.nanoTime();
                try {
                    runRow(row, observed, dao, config);
                    observed.put("status", "observed");
                } catch (Throwable error) {
                    observed.put("status", "error").put("error", describe(error));
                    throw error;
                } finally {
                    observed.put("elapsedMillis", (System.nanoTime() - start) / 1000000);
                }
            }
            ok = true;
        } catch (Throwable error) {
            try { report.put("failure", describe(error)); } catch (Exception ignored) { }
        } finally {
            try {
                if (database != null) call(database, "close");
                boolean cleaned = scratch != null && scratch.cleanup();
                report.put("cleanup", new JSONObject().put("databaseClosed", database != null)
                    .put("scratchRemoved", cleaned).put("server", "not-used"));
                ok &= cleaned;
            } catch (Throwable error) {
                ok = false;
                try { report.put("cleanupFailure", describe(error)); } catch (Exception ignored) { }
            }
            // No result file in the user's installation: host captures this exact JSON.
            status.putString("stream", "REPLACE_JS_ORACLE_BASE64=" + Base64.encodeToString(
                report.toString().getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP) + "\n");
            finish(ok ? -1 : 1, status);
        }
    }

    private void runRow(JSONObject row, JSONObject out, Object dao, Object config) throws Exception {
        List<?> previous = (List<?>) call(dao, "getAll");
        ruleArrayCall(dao, "delete", previous.toArray());
        JSONArray rules = row.getJSONArray("rules");
        Object[] entities = new Object[rules.length()];
        // Only a rule the run itself turns off is a rule the run disabled; a rule
        // the corpus seeds disabled is not this row's side effect.
        Set<String> enabledBefore = new LinkedHashSet<>();
        for (int i = 0; i < rules.length(); i++) {
            JSONObject input = rules.getJSONObject(i);
            Object rule = construct("io.legado.app.data.entities.ReplaceRule");
            call(rule, "setId", (long) i + 1);
            for (String name : new String[]{"name", "pattern", "replacement", "scope", "excludeScope"}) {
                if (input.has(name)) call(rule, "set" + upper(name), input.getString(name));
            }
            for (String name : new String[]{"scopeContent", "scopeTitle", "isRegex", "isEnabled"}) {
                if (input.has(name)) call(rule, "set" + upper(name.startsWith("is") ? name.substring(2) : name),
                    input.getBoolean(name));
            }
            call(rule, "setOrder", input.optInt("sortOrder", 0));
            call(rule, "setTimeoutMillisecond", input.optLong("timeoutMillisecond", 3000));
            if ((Boolean) call(rule, "isEnabled")) enabledBefore.add(input.getString("name"));
            entities[i] = rule;
        }
        ruleArrayCall(dao, "insert", entities);
        Object book = construct("io.legado.app.data.entities.Book");
        call(book, "setName", row.getString("bookName"));
        call(book, "setOrigin", row.getString("bookOrigin"));
        call(book, "setBookUrl", "https://replace-js-49.invalid/" + row.getString("id"));
        Object chapter = construct("io.legado.app.data.entities.BookChapter");
        call(chapter, "setTitle", row.getString("chapterTitle"));
        Object companion = loader.loadClass("io.legado.app.help.book.ContentProcessor")
            .getField("Companion").get(null);
        Object processor = call(companion, "get", book);
        // The corpus reuses a book identity; refresh the cached processor through
        // its real DAO selection entry after replacing this scratch row's rules.
        call(processor, "upReplaceRules");
        List<?> titleRules = (List<?>) call(processor, "getTitleReplaceRules");
        List<?> contentRules = (List<?>) call(processor, "getContentReplaceRules");
        out.put("selection", new JSONObject().put("title", names(titleRules)).put("content", names(contentRules)))
            .put("useReplaceRule", call(book, "getUseReplaceRule"))
            .put("reSegment", call(book, "getReSegment"))
            .put("converterType", call(config, "getChineseConverterType"));
        out.put("title", call(chapter, "getDisplayTitle", titleRules, true, true));
        Object result = call(processor, "getContent", book, chapter, row.getString("rawContent"),
            false, true, true, true);
        // BookContent.toString is the frozen join of its returned textList. Record
        // the complete text and every other return field; never normalize.
        out.put("content", result.toString())
            .put("textList", new JSONArray((List<?>) call(result, "getTextList")))
            .put("sameTitleRemoved", call(result, "getSameTitleRemoved"))
            .put("effectiveRules", names((List<?>) call(result, "getEffectiveReplaceRules")));
        JSONArray disabled = new JSONArray();
        for (Object rule : (List<?>) call(dao, "getAll")) {
            String name = (String) call(rule, "getName");
            if (enabledBefore.contains(name) && !(Boolean) call(rule, "isEnabled")) disabled.put(name);
        }
        out.put("rulesDisabledByRun", disabled);
        if (row.getString("id").equals("js-timeout")) {
            out.put("timeoutObserved", disabled.length() != 0)
                .put("restartObservation", "not-demonstrated: a completed call cannot show the 3 s "
                    + "appCtx.restart() that the frozen handler only schedules while its worker is "
                    + "still active; no input was amplified");
        }
    }

    private Object singleton(String name) throws Exception { return loader.loadClass(name).getField("INSTANCE").get(null); }
    private Object construct(String name) throws Exception { return loader.loadClass(name).getConstructor().newInstance(); }
    private void ruleArrayCall(Object dao, String method, Object[] items) throws Exception {
        Object array = Array.newInstance(loader.loadClass("io.legado.app.data.entities.ReplaceRule"), items.length);
        for (int i = 0; i < items.length; i++) Array.set(array, i, items[i]);
        call(dao, method, array);
    }
    private static JSONArray names(List<?> rules) throws Exception {
        if (rules == null) return null;
        JSONArray result = new JSONArray();
        for (Object rule : rules) result.put(call(rule, "getName"));
        return result;
    }
    private static Object call(Object target, String name, Object... args) throws Exception {
        for (Method method : target.getClass().getMethods()) {
            if (!method.getName().equals(name) || method.getParameterTypes().length != args.length) continue;
            boolean matches = true;
            Class<?>[] types = method.getParameterTypes();
            for (int i = 0; i < types.length; i++) {
                if (args[i] != null && !types[i].isPrimitive() && !types[i].isInstance(args[i])) matches = false;
            }
            if (matches) return method.invoke(target, args);
        }
        throw new NoSuchMethodException(target.getClass().getName() + "." + name);
    }
    private static String upper(String name) { return Character.toUpperCase(name.charAt(0)) + name.substring(1); }
    private static String describe(Throwable error) {
        StringBuilder result = new StringBuilder(error.toString());
        while (error.getCause() != null) { error = error.getCause(); result.append(" <- ").append(error); }
        return result.toString();
    }
    private static String hash(byte[] bytes) throws Exception {
        StringBuilder result = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(bytes)) result.append(String.format("%02x", b & 255));
        return result.toString();
    }

    /** Storage-only wrapper. Frozen code and target APK assets/resources stay intact. */
    private static final class ScratchContext extends ContextWrapper {
        static final String PREFIX = "liber_replace_js_49_";
        final File root;
        final Set<String> preferences = new LinkedHashSet<>();
        ScratchContext(Context base) {
            super(base);
            root = new File(base.getCacheDir(), "liber-replace-js-49");
            if (root.exists()) throw new IllegalStateException("scratch already exists; inspect before retrying: " + root);
            if (!root.mkdirs()) throw new IllegalStateException("cannot create scratch");
        }
        File directory(String name) { File file = new File(root, name); file.mkdirs(); return file; }
        @Override public File getFilesDir() { return directory("files"); }
        @Override public File getCacheDir() { return directory("cache"); }
        @Override public File getNoBackupFilesDir() { return directory("no-backup"); }
        @Override public File getCodeCacheDir() { return directory("code-cache"); }
        @Override public File getDir(String name, int mode) { return directory("dir-" + name); }
        @Override public File getExternalFilesDir(String type) { return directory("external-" + (type == null ? "files" : type)); }
        @Override public File[] getExternalFilesDirs(String type) { return new File[]{getExternalFilesDir(type)}; }
        @Override public File getExternalCacheDir() { return directory("external-cache"); }
        @Override public File[] getExternalCacheDirs() { return new File[]{getExternalCacheDir()}; }
        @Override public File getDatabasePath(String name) { return new File(directory("databases"), name); }
        @Override public SQLiteDatabase openOrCreateDatabase(String name, int mode, SQLiteDatabase.CursorFactory factory) {
            return openOrCreateDatabase(name, mode, factory, null);
        }
        @Override public SQLiteDatabase openOrCreateDatabase(String name, int mode, SQLiteDatabase.CursorFactory factory,
                DatabaseErrorHandler handler) {
            return SQLiteDatabase.openDatabase(getDatabasePath(name).getPath(), factory,
                SQLiteDatabase.CREATE_IF_NECESSARY | SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING, handler);
        }
        @Override public boolean deleteDatabase(String name) { return SQLiteDatabase.deleteDatabase(getDatabasePath(name)); }
        @Override public SharedPreferences getSharedPreferences(String name, int mode) {
            String scoped = PREFIX + name;
            if (!preferences.contains(scoped) && !getBaseContext().getSharedPreferences(scoped, mode).getAll().isEmpty()) {
                throw new IllegalStateException("scratch preferences already contain data: " + scoped);
            }
            preferences.add(scoped);
            return getBaseContext().getSharedPreferences(scoped, mode);
        }
        boolean cleanup() {
            boolean ok = true;
            for (String name : preferences) {
                // commit fences any earlier apply writes before deleting only our file.
                ok &= getBaseContext().getSharedPreferences(name, 0).edit().clear().commit();
                ok &= getBaseContext().deleteSharedPreferences(name);
            }
            return remove(root) && ok;
        }
        private static boolean remove(File file) {
            File[] children = file.listFiles();
            boolean ok = true;
            if (children != null) for (File child : children) ok &= remove(child);
            return file.delete() && ok;
        }
    }
}
