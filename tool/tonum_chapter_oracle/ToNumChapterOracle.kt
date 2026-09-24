// The frozen toNumChapter harness: compiles against the frozen Legado
// revision's `AppPattern.kt` and `StringUtils.kt`, calls them for every row of
// `fixtures.json` and writes `golden.json`.
//
// `java.toNumChapter` itself lives in `JsExtensions.kt`, which names Rhino, the
// app's own `AppConfig` and Android types and therefore cannot be compiled on a
// desktop JVM. Its eight-line body is transcribed here verbatim
// (`JsExtensions.kt:905-913`) and verified against the frozen file at run time,
// so a drift in the frozen text or in this transcription fails the run instead
// of producing a golden nobody can re-derive.
//
// This is NOT the four-stage device oracle: it is a source execution of the two
// frozen functions the member composes, on a host JVM. See README.md.
package tool.tonum

import com.google.gson.GsonBuilder
import io.legado.app.constant.AppPattern
import io.legado.app.utils.StringUtils
import java.io.File

data class FrozenSource(
    val path: String = "",
    val sha1: String = "",
    val role: String = "",
)

data class Case(
    val name: String,
    val input: String?,
    val note: String = "",
)

data class Fixtures(
    val baseline: String = "",
    val frozenSources: List<FrozenSource> = emptyList(),
    val note: String = "",
    val cases: List<Case> = emptyList(),
)

/** The frozen `toNumChapter` body, character for character from `JsExtensions.kt:906-912`. */
private val FROZEN_BODY = """
    s ?: return null
    val matcher = AppPattern.titleNumPattern.matcher(s)
    if (matcher.find()) {
        val intStr = StringUtils.stringToInt(matcher.group(2))
        return "${'$'}{matcher.group(1)}${'$'}{intStr}${'$'}{matcher.group(3)}"
    }
    return s
""".trimIndent()

/**
 * `java.toNumChapter` as the frozen `JsExtensions` object defines it.
 *
 * The body above is what this function does; the harness refuses to write a
 * golden unless the frozen source still contains it.
 */
fun toNumChapter(s: String?): String? {
    s ?: return null
    val matcher = AppPattern.titleNumPattern.matcher(s)
    if (matcher.find()) {
        val intStr = StringUtils.stringToInt(matcher.group(2))
        return "${matcher.group(1)}${intStr}${matcher.group(3)}"
    }
    return s
}

private val whitespace = Regex("\\s+")

/**
 * Fails the run unless [frozenPath] still contains the transcribed body.
 *
 * The comparison drops every whitespace character, so re-indentation is not a
 * drift but a changed expression is.
 */
private fun requireTranscription(frozenPath: File) {
    val frozen = whitespace.replace(frozenPath.readText(Charsets.UTF_8), "")
    val transcribed = whitespace.replace(FROZEN_BODY, "")
    check(frozen.contains(transcribed)) {
        "${frozenPath.path} no longer contains the transcribed toNumChapter body; " +
            "re-read JsExtensions.kt and update FROZEN_BODY"
    }
}

fun main(args: Array<String>) {
    require(args.size == 3) {
        "usage: ToNumChapterOracleKt <fixtures.json> <golden.json> <frozen JsExtensions.kt>"
    }
    val gson = GsonBuilder()
        .setPrettyPrinting()
        .disableHtmlEscaping()
        .serializeNulls()
        .create()
    val fixtures = gson.fromJson(File(args[0]).readText(Charsets.UTF_8), Fixtures::class.java)
    val jsExtensions = fixtures.frozenSources.singleOrNull {
        it.path.endsWith("JsExtensions.kt")
    } ?: error("fixtures.json must name the frozen JsExtensions.kt")
    if (!args[2].replace('\\', '/').endsWith(jsExtensions.path)) {
        error("${args[2]} is not the frozen ${jsExtensions.path}")
    }
    requireTranscription(File(args[2]))

    val golden = LinkedHashMap<String, String?>()
    for (case in fixtures.cases) {
        val first = toNumChapter(case.input)
        val second = toNumChapter(case.input)
        check(first == second) {
            "case ${case.name} is not deterministic; remove it from the corpus"
        }
        golden[case.name] = first
    }
    File(args[1]).writeText(gson.toJson(golden), Charsets.UTF_8)
    println("wrote ${golden.size} rows from ${fixtures.baseline} (${jsExtensions.sha1})")
}
