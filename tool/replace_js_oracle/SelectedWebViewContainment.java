package io.liber.oracle.nested;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.os.Build;
import android.webkit.CookieManager;
import android.webkit.WebView;
import org.json.JSONObject;
import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** Selected timeout crash logging may initialize WebView; fail before rules if its paths escape. */
final class SelectedWebViewContainment {
    static final String SUFFIX = "liber-replace-js-selected";
    static final String PROVIDER = "com.google.android.webview";
    static final String VERSION = "158.0.8127.2";
    private SelectedWebViewContainment() { }

    static void setSuffix() {
        if (Build.VERSION.SDK_INT < 28) throw new IllegalStateException("WebView suffix requires API 28");
        WebView.setDataDirectorySuffix(SUFFIX);
    }

    static JSONObject verify(Context app, Context target, File root) throws Exception {
        JSONObject config = config(app.getClassLoader());
        if (!config.isNull("dataDirectoryBasePath") || !config.isNull("cacheDirectoryBasePath") ||
                config.getBoolean("dataDirectorySuffixKey")) throw new IllegalStateException("AndroidX WebView override present");
        if (app.isDeviceProtectedStorage() || app.getApplicationContext() != app)
            throw new IllegalStateException("WebView application context substituted or device-protected");
        File data = app.getDir("webview_" + SUFFIX, Context.MODE_PRIVATE);
        File cache = new File(app.getCacheDir(), "webview_" + SUFFIX);
        File textures = app.getDir("textures", Context.MODE_PRIVATE);
        inside(root, data); inside(root, cache); inside(root, textures);
        Context resolved = app.getApplicationContext();
        if (!same(data, resolved.getDir("webview_" + SUFFIX, Context.MODE_PRIVATE)) ||
            !same(cache, new File(resolved.getCacheDir(), "webview_" + SUFFIX)) ||
            !same(textures, resolved.getDir("textures", Context.MODE_PRIVATE)))
            throw new IllegalStateException("resolved WebView context paths differ");
        File installation = new File(target.getApplicationInfo().dataDir);
        JSONObject before = profile(installation);
        // The standard query reports the candidate without loading WebView.
        PackageInfo candidate = WebView.getCurrentWebViewPackage();
        if (candidate == null || !PROVIDER.equals(candidate.packageName) || !VERSION.equals(candidate.versionName))
            throw new IllegalStateException("candidate WebView provider differs from pin before initialization");
        // Same provider initialization used by AUTH; no cookie operation or navigation.
        CookieManager manager = CookieManager.getInstance();
        PackageInfo provider = WebView.getCurrentWebViewPackage();
        if (provider == null || !PROVIDER.equals(provider.packageName) || !VERSION.equals(provider.versionName) ||
                candidate.getLongVersionCode() != provider.getLongVersionCode())
            throw new IllegalStateException("current WebView provider differs from candidate pin");
        JSONObject actual = paths(manager.getClass().getClassLoader(), target.getClassLoader());
        if (!same(data, new File(actual.getString("data"))) || !same(cache, new File(actual.getString("cache"))) ||
            !same(textures, new File(actual.getString("textures")))) throw new IllegalStateException("WebView PathUtils escaped owned scratch");
        JSONObject after = profile(installation);
        if (!sameProfile(before, after)) throw new IllegalStateException("installation WebView metadata changed");
        return new JSONObject().put("scratchCanonicalRoot", root.getCanonicalPath())
            .put("suffix", SUFFIX).put("suffixStatus", "set-in-Instrumentation.newApplication")
            .put("androidxProcessGlobalConfig", config).put("applicationClass", app.getClass().getName())
            .put("resolvedApplicationContextIsApplication", true).put("deviceProtected", false)
            .put("computed", new JSONObject().put("data", data.getCanonicalPath()).put("cache", cache.getCanonicalPath())
                .put("textures", textures.getCanonicalPath()))
            .put("actual", actual).put("candidate", new JSONObject().put("package", candidate.packageName)
                .put("versionName", candidate.versionName).put("versionCode", candidate.getLongVersionCode()))
            .put("provider", new JSONObject().put("package", provider.packageName)
                .put("versionName", provider.versionName).put("versionCode", provider.getLongVersionCode()))
            .put("realProfileBefore", before).put("realProfileAfter", after)
            .put("pathSource", "org.chromium.base.PathUtils via provider classloader");
    }

    private static JSONObject config(ClassLoader loader) throws Exception {
        JSONObject result = new JSONObject().put("classPresent", false).put("configSet", false)
            .put("dataDirectoryBasePath", JSONObject.NULL).put("cacheDirectoryBasePath", JSONObject.NULL)
            .put("dataDirectorySuffixKey", false);
        Class<?> holder;
        try { holder = Class.forName("androidx.webkit.ProcessGlobalConfig", true, loader); }
        catch (ClassNotFoundException | NoClassDefFoundError absent) { return result; }
        result.put("classPresent", true);
        Field field = holder.getDeclaredField("sProcessGlobalConfig"); field.setAccessible(true);
        Object reference = field.get(null);
        if (reference == null) return result;
        Object value = reference.getClass().getMethod("get").invoke(reference);
        if (value == null) return result;
        Map<?, ?> map = (Map<?, ?>) value;
        Object data = map.get("DATA_DIRECTORY_BASE_PATH"), cache = map.get("CACHE_DIRECTORY_BASE_PATH");
        return result.put("configSet", true).put("dataDirectoryBasePath", data == null ? JSONObject.NULL : data.toString())
            .put("cacheDirectoryBasePath", cache == null ? JSONObject.NULL : cache.toString())
            .put("dataDirectorySuffixKey", map.containsKey("DATA_DIRECTORY_SUFFIX"));
    }

    private static JSONObject paths(ClassLoader providerLoader, ClassLoader appLoader) throws Exception {
        List<ClassLoader> loaders = new ArrayList<>();
        if (providerLoader != null) loaders.add(providerLoader);
        if (appLoader != null) loaders.add(appLoader);
        try {
            Class<?> factory = Class.forName("android.webkit.WebViewFactory");
            Method method = factory.getDeclaredMethod("getProvider"); method.setAccessible(true);
            Object provider = method.invoke(null);
            if (provider != null && provider.getClass().getClassLoader() != null) loaders.add(provider.getClass().getClassLoader());
        } catch (Throwable ignored) { /* The provider classloader remains the primary source. */ }
        for (int i = 0; i < loaders.size(); i++) {
            try {
                Class<?> owner = Class.forName("org.chromium.base.PathUtils", true, loaders.get(i));
                return new JSONObject().put("loadedFrom", "provider-classloader-" + i)
                    .put("data", new File((String)owner.getMethod("getDataDirectory").invoke(null)).getCanonicalPath())
                    .put("cache", new File((String)owner.getMethod("getCacheDirectory").invoke(null)).getCanonicalPath())
                    .put("textures", new File((String)owner.getMethod("getThumbnailCacheDirectory").invoke(null)).getCanonicalPath());
            } catch (ClassNotFoundException | NoClassDefFoundError absent) { /* Try the next loader. */ }
        }
        throw new IllegalStateException("WebView PathUtils unavailable");
    }
    private static void inside(File root, File value) throws Exception {
        String r = root.getCanonicalPath(), p = value.getCanonicalPath();
        if (!p.startsWith(r + File.separator)) throw new IllegalStateException("WebView path outside owned scratch: " + p);
    }
    private static boolean same(File a, File b) throws Exception { return a.getCanonicalPath().equals(b.getCanonicalPath()); }
    private static JSONObject metadata(File file) throws Exception {
        return new JSONObject().put("path", file.getCanonicalPath()).put("exists", file.exists())
            .put("directory", file.isDirectory()).put("length", file.length()).put("lastModified", file.lastModified());
    }
    private static JSONObject profile(File dataDir) throws Exception {
        return new JSONObject().put("app_webview", metadata(new File(dataDir, "app_webview")))
            .put("app_webview_suffixed", metadata(new File(dataDir, "app_webview_" + SUFFIX)));
    }
    private static boolean sameProfile(JSONObject before, JSONObject after) throws Exception {
        for (String name : new String[]{"app_webview", "app_webview_suffixed"}) {
            JSONObject a = before.getJSONObject(name), b = after.getJSONObject(name);
            if (a.getBoolean("exists") != b.getBoolean("exists") || a.getBoolean("directory") != b.getBoolean("directory") ||
                a.getLong("length") != b.getLong("length") || a.getLong("lastModified") != b.getLong("lastModified")) return false;
        }
        return true;
    }
}
