// The two frozen members `HtmlFormatter.kt` calls, supplied for the compile
// classpath because the files that really declare them cannot be compiled on a
// desktop JVM:
//
// - `NetworkUtils.kt` imports hutool's `Validator`, OkHttp's
//   `PublicSuffixDatabase`, Android's `ConnectivityManager`/`NetworkCapabilities`
//   and splitties' `connectivityManager`;
// - `StringExtensions.kt` imports `android.icu.text.Collator`,
//   `android.net.Uri` and hutool's `URLEncodeUtil`.
//
// `HtmlFormatter.kt` itself needs only `getAbsoluteURL(URL?, String)` from the
// first and `isAbsUrl`/`isDataUrl` from the second, so those three members are
// transcribed here character for character from the frozen files' *bodies*, and
// `HtmlContentOracle` fails the run unless each frozen file still contains its
// transcription (whitespace-normalised). The one frozen statement dropped is
// `AppLog.put("网址拼接出错\n${e.localizedMessage}", e)`: `AppLog` writes through
// Android's `Log` (see `FrozenDebugStub.kt` for the same reason), it is reached
// only by a malformed base URL, and no corpus case has one.
//
// `isDataUrl` calls the frozen `AppPattern.dataUriRegex`, which is compiled from
// the frozen bytes by `run_golden.sh` — not transcribed.
package io.legado.app.utils

import io.legado.app.constant.AppPattern
import java.net.URL

object NetworkUtils {

    /** `NetworkUtils.kt:174-189`, transcribed. */
    fun getAbsoluteURL(baseURL: URL?, relativePath: String): String {
        val relativePathTrim = relativePath.trim()
        if (baseURL == null) return relativePathTrim
        if (relativePathTrim.isAbsUrl()) return relativePathTrim
        if (relativePathTrim.isDataUrl()) return relativePathTrim
        if (relativePathTrim.startsWith("javascript")) return ""
        var relativeUrl = relativePathTrim
        try {
            val parseUrl = URL(baseURL, relativePath)
            relativeUrl = parseUrl.toString()
            return relativeUrl
        } catch (e: Exception) {
            // AppLog.put("网址拼接出错\n${e.localizedMessage}", e) — Android's log.
        }
        return relativeUrl
    }
}

/** `StringExtensions.kt:36-39`, transcribed. */
private fun String?.isAbsUrl() =
    this?.let {
        it.startsWith("http://", true) || it.startsWith("https://", true)
    } ?: false

/** `StringExtensions.kt:41-44`, transcribed. */
private fun String?.isDataUrl() =
    this?.let {
        AppPattern.dataUriRegex.matches(it)
    } ?: false
