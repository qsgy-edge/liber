// The frozen content stage's *replace pass* oracle: compiles the frozen Legado
// revision's `AnalyzeRule.kt`, `RuleDataInterface.kt`, `AnalyzeByRegex.kt`,
// `HtmlFormatter.kt` and `AppPattern.kt` together with the frozen script engine
// (`modules/rhino`, over the revision's own Rhino), runs the replace stage of
// `BookContent.kt:135-142` over `replace_fixtures.json`, and writes
// `evidence/jvm-host/replace-golden.json` + `replace-manifest.json`.
//
// The deciding frozen lines are BookContent.kt:135-142:
//
//     var contentStr = contentList.joinToString("\n")
//     //全文替换
//     val replaceRegex = contentRule.replaceRegex
//     if (!replaceRegex.isNullOrEmpty()) {
//         contentStr = contentStr.split(AppPattern.LFRegex).joinToString("\n") { it.trim() }
//         contentStr = analyzeRule.getString(replaceRegex, contentStr)
//         contentStr = contentStr.split(AppPattern.LFRegex).joinToString("\n") { "　　$it" }
//     }
//
// and the read above it (`:176-181`), which this harness runs as the frozen
// `AnalyzeRule.getBString(contentRule.content, unescape = false)` plus
// `HtmlFormatter.formatKeepImg` plus the `&`-guarded unescape. Both blocks are
// transcribed here and the run refuses a transcription the frozen file no longer
// contains; everything they call — the rule splitter, the `{{...}}`/`@get:`
// substitution, the `##` field split, the regex replacement, the script eval —
// is the frozen bytes.
//
// `AnalyzeRule.kt` cannot be compiled as the frozen app builds it: it names Room
// entities, the Android-bound help classes, the jsoup/json-path analysis and the
// OkHttp response type. `stubs/` supplies those members for the compile
// classpath (each documented, each refusing by name where it is not reached),
// and the one Android member on the deciding path — `TextUtils.isEmpty` — is
// supplied with AOSP's implementation. See README.md.
//
// This is NOT the four-stage device oracle: it is a source execution of the
// frozen replace pass on a host JVM.
package tool.htmlcontent

import com.google.gson.GsonBuilder
import io.legado.app.constant.AppPattern
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.ExtractionAnswer
import io.legado.app.utils.HtmlFormatter
import org.apache.commons.text.StringEscapeUtils
import java.io.File
import java.net.URL
import java.security.MessageDigest

data class ReplaceSource(
    val path: String = "",
    val sha1: String = "",
    val role: String = "",
)

data class ScriptModule(
    val root: String = "",
    val files: Int = 0,
    val treeSha1: String = "",
    val role: String = "",
    val treeSha1Recipe: String = "",
)

data class ReplaceCase(
    val name: String,
    val shape: String = "",
    val note: String = "",
    val pageHtml: String = "",
    val pageValues: List<String> = emptyList(),
    val contentField: String = "",
    val replaceRegex: String = "",
    val bookName: String = "",
    val bookAuthor: String = "",
    val chapterTitle: String = "",
    val pageUrl: String = "",
    val pageBody: String = "",
)

data class ReplaceFixtures(
    val schemaVersion: Int = 0,
    val fixtureId: String = "",
    val corpusVersion: Int = 0,
    val baseline: String = "",
    val surface: String = "",
    val note: String = "",
    val frozenSources: List<ReplaceSource> = emptyList(),
    val scriptModule: ScriptModule = ScriptModule(),
    val cases: List<ReplaceCase> = emptyList(),
)

/** One case's answer: every value the frozen path produces on the way to the
 * stage's return value. */
data class ReplaceRow(
    val shape: String,
    val note: String,
    val pageRules: List<String?>,
    val fieldReads: List<String>,
    val pageReads: List<String>,
    val joined: String,
    val trimmed: String?,
    val replaced: String?,
    val content: String,
)

/** The frozen content field read and the per-page pass (`BookContent.kt:176-181`). */
private val FROZEN_PAGE_READ = """
    var content = analyzeRule.getString(contentRule.content, unescape = false)
    content = HtmlFormatter.formatKeepImg(content, rUrl)
    if (content.indexOf('&') > -1) {
        content = StringEscapeUtils.unescapeHtml4(content)
    }
""".trimIndent()

/** The frozen replace stage (`BookContent.kt:133-142`). */
private val FROZEN_REPLACE_STAGE = """
    var contentStr = contentList.joinToString("\n")
    //全文替换
    val replaceRegex = contentRule.replaceRegex
    if (!replaceRegex.isNullOrEmpty()) {
        contentStr = contentStr.split(AppPattern.LFRegex).joinToString("\n") { it.trim() }
        contentStr = analyzeRule.getString(replaceRegex, contentStr)
        contentStr = contentStr.split(AppPattern.LFRegex).joinToString("\n") { "　　${'$'}it" }
    }
""".trimIndent()

/** `MapExtensions.kt:21-33`, transcribed into `stubs/utils.kt`. */
private val FROZEN_GET_OR_PUT_LIMIT = """
    inline fun <K, V> MutableMap<K, V>.getOrPutLimit(key: K, maxSize: Int, defaultValue: () -> V): V {
        var value = get(key)
        if (containsKey(key)) {
            @Suppress("UNCHECKED_CAST")
            return value as V
        }
        value = defaultValue()
        if (size < maxSize) {
            put(key, value)
        }
        return value
    }
""".trimIndent()

/** `StringExtensions.kt:46-55`, transcribed. */
private val FROZEN_IS_JSON = """
    fun String?.isJson(): Boolean =
        this?.run {
            val str = this.trim()
            when {
                str.startsWith("{") && str.endsWith("}") -> true
                str.startsWith("[") && str.endsWith("]") -> true
                else -> false
            }
        } ?: false
""".trimIndent()

/** `StringExtensions.kt:81-84`, transcribed. */
private val FROZEN_SPLIT_NOT_BLANK = """
    fun String.splitNotBlank(vararg delimiter: String, limit: Int = 0): Array<String> = run {
        this.split(*delimiter, limit = limit).map { it.trim() }.filterNot { it.isBlank() }
            .toTypedArray()
    }
""".trimIndent()

/** `StringExtensions.kt:36-44`, transcribed (also checked by #101's harness). */
private val FROZEN_IS_ABS_URL = """
    fun String?.isAbsUrl() =
        this?.let {
            it.startsWith("http://", true) || it.startsWith("https://", true)
        } ?: false
""".trimIndent()

/** `ThrowableExtensions.kt:5-13`, transcribed. */
private val FROZEN_STACK_TRACE_STR = """
    val Throwable.stackTraceStr: String
        get() {
            val stackTrace = stackTraceToString()
            val lMsg = this.localizedMessage ?: "noErrorMsg"
            return when {
                stackTrace.isNotEmpty() -> stackTrace
                else -> lMsg
            }
        }
""".trimIndent()

/** `SharedJsScope.kt:36-38`, transcribed into `stubs/help_source.kt`. */
private val FROZEN_SHARE_SCOPE_GUARD = """
    fun getScope(jsLib: String?, coroutineContext: CoroutineContext?): Scriptable? {
        if (jsLib.isNullOrBlank()) {
            return null
        }
""".trimIndent()

// `AnalyzeUrl.paramPattern` (`AnalyzeUrl.kt:658`) is transcribed once per step,
// because the two steps cannot share one declaration: `FrozenAnalyzeUrlStub.kt`
// is the `object` #101's content step compiles, `stubs/analyze_url.kt` the class
// this step compiles. `HtmlContentOracle`'s [FROZEN_PARAM_PATTERN] checks the
// expression both transcriptions carry.

/** The frozen `ContentRule` field the stage reads (`ContentRule.kt:17`). */
private class FrozenContentRule(val replaceRegex: String?, val content: String?)

/** One page's frozen read: the content field's value (its own `##` replacement
 * already applied) and the value after the per-page HTML pass. */
private class PageRead(val field: String, val formatted: String)

/**
 * `BookContent.kt:176-181`: the content field read, the per-page HTML pass and
 * the `&`-guarded unescape. The run refuses unless [FROZEN_PAGE_READ], the
 * frozen text these statements transcribe, is still in `BookContent.kt`.
 */
private fun frozenPageRead(
    analyzeRule: AnalyzeRule,
    contentRule: FrozenContentRule,
    rUrl: URL?,
): PageRead {
    var content = analyzeRule.getString(contentRule.content, unescape = false)
    val field = content
    content = HtmlFormatter.formatKeepImg(content, rUrl)
    if (content.indexOf('&') > -1) {
        content = StringEscapeUtils.unescapeHtml4(content)
    }
    return PageRead(field, content)
}

/** One case's replace stage: the frozen return value and the two values the
 * frozen computes on the way to it, which the golden records so a reader can
 * see which statement decided a row. */
private class StageResult(
    val content: String,
    val trimmed: String?,
    val replaced: String?,
)

/**
 * `BookContent.kt:133-142`: the join, the trim, the replacement and the indent.
 * The run refuses unless [FROZEN_REPLACE_STAGE], the frozen text these
 * statements transcribe, is still in `BookContent.kt`.
 */
private fun frozenReplaceStage(
    contentList: List<String>,
    contentRule: FrozenContentRule,
    analyzeRule: AnalyzeRule,
): StageResult {
    var contentStr = contentList.joinToString("\n")
    //全文替换
    val replaceRegex = contentRule.replaceRegex
    var trimmed: String? = null
    var replaced: String? = null
    if (!replaceRegex.isNullOrEmpty()) {
        trimmed = contentStr.split(AppPattern.LFRegex).joinToString("\n") { it.trim() }
        replaced = analyzeRule.getString(replaceRegex, trimmed)
        contentStr = replaced.split(AppPattern.LFRegex).joinToString("\n") { "　　$it" }
    }
    return StageResult(contentStr, trimmed, replaced)
}

private fun sha1(file: File): String {
    val digest = MessageDigest.getInstance("SHA-1")
    return digest.digest(file.readBytes()).joinToString("") { "%02x".format(it) }
}

/** The cases' values, answered by the frozen's own analysis. */
private fun readCase(case: ReplaceCase): ReplaceRow {
    val base = case.pageUrl
    val source = BookSource(bookSourceUrl = "http://example.test")
    val book = Book(
        name = case.bookName,
        author = case.bookAuthor,
        bookUrl = "http://example.test/book/1",
        origin = "http://example.test",
    )
    val chapter = BookChapter(url = base, title = case.chapterTitle)
    val contentRule = FrozenContentRule(case.replaceRegex, case.contentField)

    // One page at a time: the frozen `analyzeContent` builds its own
    // `AnalyzeRule` per page (`BookContent.kt:160-181`).
    val pageRules = mutableListOf<String?>()
    val fieldReads = mutableListOf<String>()
    val pageReads = mutableListOf<String>()
    for (value in case.pageValues) {
        val analyzeRule = AnalyzeRule(book, source)
        analyzeRule.setContent(case.pageBody, base)
        val rUrl = analyzeRule.setRedirectUrl(base)
        analyzeRule.chapter = chapter
        // The selector engine is not compiled here: it answers the value this
        // case declares for the page (`stubs/analysis.kt`).
        ExtractionAnswer.reset()
        ExtractionAnswer.declared = value
        val read = frozenPageRead(analyzeRule, contentRule, rUrl)
        fieldReads.add(read.field)
        pageReads.add(read.formatted)
        pageRules.add(ExtractionAnswer.askedRule)
    }

    // The stage runs on the outer `AnalyzeRule` (`BookContent.kt:64-66`), whose
    // content is the first page's body.
    val analyzeRule = AnalyzeRule(book, source)
    analyzeRule.setContent(case.pageBody, base)
    analyzeRule.setRedirectUrl(base)
    analyzeRule.chapter = chapter
    val stage = frozenReplaceStage(pageReads, contentRule, analyzeRule)
    return ReplaceRow(
        shape = case.shape,
        note = case.note,
        pageRules = pageRules,
        fieldReads = fieldReads,
        pageReads = pageReads,
        joined = pageReads.joinToString("\n"),
        trimmed = stage.trimmed,
        replaced = stage.replaced,
        content = stage.content,
    )
}

fun main(args: Array<String>) {
    require(args.size == 5) {
        "usage: ContentReplaceOracleKt <replace_fixtures.json> <replace-golden.json> " +
            "<replace-manifest.json> <frozen root> <toolchain.json>"
    }
    val gson = GsonBuilder()
        .setPrettyPrinting()
        .disableHtmlEscaping()
        .serializeNulls()
        .create()
    val fixtures = gson.fromJson(
        File(args[0]).readText(Charsets.UTF_8),
        ReplaceFixtures::class.java,
    )
    val frozenRoot = File(args[3])
    require(frozenRoot.isDirectory) { "${frozenRoot.path} is not a directory" }

    // The golden is labelled with the frozen bytes it was produced from.
    val verified = fixtures.frozenSources.map { declared ->
        val file = File(frozenRoot, declared.path)
        check(file.isFile) { "${file.path} is missing" }
        val actual = sha1(file)
        check(actual == declared.sha1) {
            "${declared.path} sha1 is $actual, replace_fixtures.json declares ${declared.sha1}"
        }
        declared
    }
    val byPath = verified.associateBy { it.path }
    fun frozenFile(name: String) = File(
        frozenRoot,
        byPath.entries.single { it.key.endsWith(name) }.key,
    )
    requireTranscription(frozenFile("BookContent.kt"), FROZEN_PAGE_READ, FROZEN_REPLACE_STAGE)
    requireTranscription(frozenFile("MapExtensions.kt"), FROZEN_GET_OR_PUT_LIMIT)
    requireTranscription(frozenFile("StringExtensions.kt"), FROZEN_IS_JSON, FROZEN_SPLIT_NOT_BLANK, FROZEN_IS_ABS_URL)
    requireTranscription(frozenFile("ThrowableExtensions.kt"), FROZEN_STACK_TRACE_STR)
    requireTranscription(frozenFile("SharedJsScope.kt"), FROZEN_SHARE_SCOPE_GUARD)
    requireTranscription(frozenFile("AnalyzeUrl.kt"), FROZEN_PARAM_PATTERN)

    // The frozen script engine is compiled from its own bytes: pin the whole
    // module, not only the files this harness happens to read.
    val moduleRoot = File(frozenRoot, fixtures.scriptModule.root)
    val moduleFiles = moduleRoot.walkTopDown()
        .filter { it.isFile && it.name.endsWith(".kt") }
        .map { it.relativeTo(frozenRoot).path.replace(File.separatorChar, '/') }
        .sorted()
        .toList()
    check(moduleFiles.size == fixtures.scriptModule.files) {
        "the frozen script module has ${moduleFiles.size} files, replace_fixtures.json declares " +
            "${fixtures.scriptModule.files}"
    }
    val tree = moduleFiles.joinToString("") { "${sha1(File(frozenRoot, it))}  $it\n" }
    val treeSha1 = MessageDigest.getInstance("SHA-1")
        .digest(tree.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
    check(treeSha1 == fixtures.scriptModule.treeSha1) {
        "the frozen script module's tree sha1 is $treeSha1, replace_fixtures.json declares " +
            fixtures.scriptModule.treeSha1
    }

    val rows = LinkedHashMap<String, ReplaceRow>()
    for (case in fixtures.cases) {
        val row = readCase(case)
        // Every case runs twice: a row that is not deterministic cannot be a
        // golden. The frozen path here reads no clock, no random source and no
        // network.
        val again = readCase(case)
        check(again == row) { "case ${case.name} is not deterministic" }
        check(!rows.containsKey(case.name)) { "case ${case.name} is declared twice" }
        rows[case.name] = row
    }

    val goldenFile = File(args[1])
    val golden = linkedMapOf<String, Any?>(
        "fixtureId" to fixtures.fixtureId,
        "corpusVersion" to fixtures.corpusVersion,
        "baseline" to fixtures.baseline,
        "surface" to fixtures.surface,
        "note" to fixtures.note,
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
        "scriptModule" to fixtures.scriptModule,
        "harness" to "tool/html_content_oracle/ContentReplaceOracle.kt",
        "fixtures" to "tool/html_content_oracle/replace_fixtures.json",
        "golden" to "tool/html_content_oracle/evidence/jvm-host/replace-golden.json",
        "goldenSha1" to sha1(goldenFile),
        "command" to "bash tool/html_content_oracle/run_golden.sh",
        "toolchain" to toolchain,
        "jvm" to "${System.getProperty("java.vendor")} " +
            "${System.getProperty("java.version")} (${System.getProperty("os.name")})",
        "recordedAt" to java.time.Instant.now().toString(),
        "determinism" to "Every case is evaluated twice and the run is refused when the two " +
            "runs differ. The frozen rule path, the formatter and the pinned Rhino read no " +
            "clock, no random source and no state.",
        "transcription" to "AnalyzeRule.kt, RuleDataInterface.kt, AnalyzeByRegex.kt, " +
            "HtmlFormatter.kt, AppPattern.kt and the frozen modules/rhino script engine are " +
            "compiled and executed as they are; the {{...}} substitutions this corpus carries " +
            "are evaluated by that engine, not by a transcription. Transcribed and verified at " +
            "run time against the frozen files: the content field read and per-page pass " +
            "(BookContent.kt:176-181), the replace stage (BookContent.kt:133-142), the " +
            "getOrPutLimit/isJson/splitNotBlank/isAbsUrl/isDataUrl helpers the rule path " +
            "reaches (MapExtensions.kt:21-33, StringExtensions.kt:36-44,46-55,81-84), " +
            "stackTraceStr (ThrowableExtensions.kt:5-13) and the shared-scope guard " +
            "(SharedJsScope.kt:36-38). The stub members this corpus never reaches are declared " +
            "in tool/html_content_oracle/stubs/ and refuse by name; android.text.TextUtils " +
            "carries AOSP's own implementation because AnalyzeRule guards its rule text with it.",
        "selectorEngine" to "The frozen content field's selector read is answered by the " +
            "fixture's declared pageValues: jsoup is not compiled here, and the extraction " +
            "itself is the product's Rust adapter's and tool/html_oracle/'s surface.",
        "deviceRow" to linkedMapOf(
            "status" to "not-run",
            "owner" to "#106",
            "reason" to "The frozen APK's own BookContent.analyzeContent is not driven here: " +
                "this host harness executes the frozen AnalyzeRule, formatter and script " +
                "engine bytes with a documented stub surface for the Android/Room-only " +
                "members. No device golden exists for this row.",
        ),
    )
    File(args[2]).writeText(gson.toJson(manifest) + "\n", Charsets.UTF_8)
    println("wrote ${rows.size} rows from ${fixtures.baseline} (${fixtures.fixtureId})")
}
