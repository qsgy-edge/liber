// The frozen content-stage HTML oracle: compiles the frozen Legado revision's
// `HtmlFormatter.kt` and runs it over every row of `fixtures.json`, followed by
// the frozen `BookContent` unescape, and writes `golden.json` + `manifest.json`.
//
// The deciding call is `BookContent.kt:178`:
//
//     content = HtmlFormatter.formatKeepImg(content, rUrl)
//
// with the two lines after it. `BookContent.kt` cannot be compiled on a desktop
// JVM (Room's `appDb`, `AppConfig`, splitties, `ChineseUtils`), so that
// three-line content pass is transcribed here and verified against the frozen
// file; `HtmlFormatter.kt` is compiled from the frozen bytes as it is.
//
// This is NOT the four-stage device oracle: it is a source execution of the
// frozen formatter on a host JVM. See README.md.
package tool.htmlcontent

import com.google.gson.GsonBuilder
import io.legado.app.utils.HtmlFormatter
import org.apache.commons.text.StringEscapeUtils
import java.io.File
import java.net.URL
import java.security.MessageDigest

data class FrozenSource(
    val path: String = "",
    val sha1: String = "",
    val role: String = "",
)

data class Case(
    val name: String,
    val input: String = "",
    val baseUrl: String? = null,
    val note: String = "",
    val compare: String = "exact",
)

data class Fixtures(
    val schemaVersion: Int = 0,
    val fixtureId: String = "",
    val corpusVersion: Int = 0,
    val baseline: String = "",
    val surface: String = "",
    val note: String = "",
    val frozenSources: List<FrozenSource> = emptyList(),
    val cases: List<Case> = emptyList(),
)

/** One case's answer: the formatter's text, and what the frozen reader stores. */
data class Row(
    val formatted: String,
    val content: String,
    val unescapeApplied: Boolean,
)

/** The frozen `BookContent.kt:178-181`, character for character. */
private val FROZEN_CONTENT_PASS = """
    content = HtmlFormatter.formatKeepImg(content, rUrl)
    if (content.indexOf('&') > -1) {
        content = StringEscapeUtils.unescapeHtml4(content)
    }
""".trimIndent()

/** `NetworkUtils.kt:174-189`, the body transcribed into `FrozenContentStubs.kt`. */
private val FROZEN_GET_ABSOLUTE_URL = """
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
            AppLog.put("网址拼接出错\n${'$'}{e.localizedMessage}", e)
        }
        return relativeUrl
    }
""".trimIndent()

/** `StringExtensions.kt:36-44`, transcribed into `FrozenContentStubs.kt`. */
private val FROZEN_IS_ABS_URL = """
    fun String?.isAbsUrl() =
        this?.let {
            it.startsWith("http://", true) || it.startsWith("https://", true)
        } ?: false
""".trimIndent()

private val FROZEN_IS_DATA_URL = """
    fun String?.isDataUrl() =
        this?.let {
            dataUriRegex.matches(it)
        } ?: false
""".trimIndent()

/** `AnalyzeUrl.kt:658`, transcribed into `FrozenAnalyzeUrlStub.kt`. */
private val FROZEN_PARAM_PATTERN =
    "val paramPattern: Pattern = Pattern.compile(\"\\\\s*,\\\\s*(?=\\\\{)\")"

private val whitespace = Regex("\\s+")

/**
 * Fails the run unless [file] still contains every snippet transcribed from it.
 *
 * The comparison drops every whitespace character, so re-indentation is not a
 * drift but a changed expression is.
 */
private fun requireTranscription(file: File, vararg snippets: String) {
    val frozen = whitespace.replace(file.readText(Charsets.UTF_8), "")
    for (snippet in snippets) {
        val transcribed = whitespace.replace(snippet, "")
        check(frozen.contains(transcribed)) {
            "${file.path} no longer contains a transcribed statement; " +
                "re-read the frozen file and update the transcription: ${snippet.take(60)}"
        }
    }
}

private fun sha1(file: File): String {
    val digest = MessageDigest.getInstance("SHA-1")
    return digest.digest(file.readBytes()).joinToString("") { "%02x".format(it) }
}

fun main(args: Array<String>) {
    require(args.size == 5) {
        "usage: HtmlContentOracleKt <fixtures.json> <golden.json> <manifest.json> " +
            "<frozen root> <toolchain.json>"
    }
    val gson = GsonBuilder()
        .setPrettyPrinting()
        .disableHtmlEscaping()
        .serializeNulls()
        .create()
    val fixtures = gson.fromJson(File(args[0]).readText(Charsets.UTF_8), Fixtures::class.java)
    val frozenRoot = File(args[3])
    require(frozenRoot.isDirectory) { "${frozenRoot.path} is not a directory" }

    // The golden is labelled with the frozen bytes it was produced from: a
    // different checkout cannot emit a golden that claims the baseline.
    val verified = fixtures.frozenSources.map { source ->
        val file = File(frozenRoot, source.path)
        check(file.isFile) { "${file.path} is missing" }
        val actual = sha1(file)
        check(actual == source.sha1) {
            "${source.path} sha1 is $actual, fixtures.json declares ${source.sha1}"
        }
        source
    }
    val byPath = verified.associateBy { it.path }
    fun frozenFile(name: String) = File(
        frozenRoot,
        byPath.entries.single { it.key.endsWith(name) }.key,
    )
    requireTranscription(frozenFile("BookContent.kt"), FROZEN_CONTENT_PASS)
    requireTranscription(frozenFile("NetworkUtils.kt"), FROZEN_GET_ABSOLUTE_URL)
    requireTranscription(
        frozenFile("StringExtensions.kt"),
        FROZEN_IS_ABS_URL,
        FROZEN_IS_DATA_URL,
    )
    requireTranscription(frozenFile("AnalyzeUrl.kt"), FROZEN_PARAM_PATTERN)

    val rows = LinkedHashMap<String, Row>()
    for (case in fixtures.cases) {
        val base = case.baseUrl?.let { URL(it) }
        // The frozen BookContent.kt:178 — the call this oracle exists for.
        val formatted = HtmlFormatter.formatKeepImg(case.input, base)
        // The frozen BookContent.kt:179-181 — the unescape the frozen runs
        // after the formatter, and only when a `&` survived it.
        val applies = formatted.indexOf('&') > -1
        val content = if (applies) StringEscapeUtils.unescapeHtml4(formatted) else formatted
        // Every case runs twice: a row that is not deterministic cannot be a
        // golden. `HtmlFormatter` reads no clock, no random source and no state.
        val again = HtmlFormatter.formatKeepImg(case.input, base)
        check(again == formatted) { "case ${case.name} is not deterministic" }
        rows[case.name] = Row(formatted = formatted, content = content, unescapeApplied = applies)
    }

    val goldenFile = File(args[1])
    val golden = linkedMapOf<String, Any?>(
        "fixtureId" to fixtures.fixtureId,
        "corpusVersion" to fixtures.corpusVersion,
        "baseline" to fixtures.baseline,
        "surface" to fixtures.surface,
        "cases" to rows,
    )
    goldenFile.writeText(gson.toJson(golden) + "\n", Charsets.UTF_8)

    @Suppress("UNCHECKED_CAST")
    val toolchain = gson.fromJson(
        File(args[4]).readText(Charsets.UTF_8),
        LinkedHashMap::class.java,
    )
    val manifest = linkedMapOf<String, Any?>(
        "surface" to fixtures.surface,
        "provenance" to "source-executed on a host JVM; NOT the four-stage device oracle",
        "baseline" to fixtures.baseline,
        "frozenSources" to verified,
        "harness" to "tool/html_content_oracle/HtmlContentOracle.kt",
        "fixtures" to "tool/html_content_oracle/fixtures.json",
        "golden" to "tool/html_content_oracle/evidence/jvm-host/golden.json",
        "goldenSha1" to sha1(goldenFile),
        "command" to "bash tool/html_content_oracle/run_golden.sh",
        "toolchain" to toolchain,
        "jvm" to "${System.getProperty("java.vendor")} " +
            "${System.getProperty("java.version")} (${System.getProperty("os.name")})",
        "recordedAt" to java.time.Instant.now().toString(),
        "determinism" to "Every case is evaluated twice and the run is refused when the two " +
            "runs differ. HtmlFormatter reads no clock, no random source and no state, so this " +
            "guards a future corpus row rather than a known non-deterministic branch.",
        "transcription" to "HtmlFormatter.kt is compiled from the frozen bytes. Four " +
            "statements reached through it are transcribed and verified at run time against " +
            "the frozen files, because the files that declare them import OkHttp/hutool/Room " +
            "and cannot be compiled on a desktop JVM: the content pass's unescape " +
            "(BookContent.kt:178-181), NetworkUtils.getAbsoluteURL (NetworkUtils.kt:174-189, " +
            "reached only by an image src), StringExtensions.isAbsUrl/isDataUrl " +
            "(StringExtensions.kt:36-44) and AnalyzeUrl.paramPattern (AnalyzeUrl.kt:658, " +
            "reached only by a templated image src). The one statement dropped from the " +
            "getAbsoluteURL transcription is its AppLog.put failure log, which writes through " +
            "Android's Log.",
        "deviceRow" to linkedMapOf(
            "status" to "not-run",
            "owner" to "#101",
            "reason" to "The frozen's own content stage inside the installed APK " +
                "(`BookContent.analyzeContent`) is not driven here: this host harness " +
                "executes the frozen HtmlFormatter bytes and a verified transcription of " +
                "the four statements around them. No device golden exists for this row.",
        ),
    )
    File(args[2]).writeText(gson.toJson(manifest) + "\n", Charsets.UTF_8)
    println("wrote ${rows.size} rows from ${fixtures.baseline} (${fixtures.fixtureId})")
}
