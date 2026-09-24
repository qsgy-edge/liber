// The frozen JSONPath harness: compiles the frozen Legado revision's
// `AnalyzeByJSonPath.kt` and `RuleAnalyzer.kt` and runs them over the documents
// and rules of `fixtures.json`, writing `golden.json`.
//
// The frozen file wraps json-path 2.9.0 directly (`JsonPath.parse(json)`, then
// `ctx.read(rule)`), so its bytes execute on a desktop JVM once the one
// Android-generated dependency is stubbed: see FrozenDebugStub.kt and README.md.
//
// The compared boundary is `AnalyzeByJSonPath.getString`, the field text a rule
// carries into the stage output. `read` is the same read recorded raw, so the
// golden says whether the library refused a rule, while `text` is what the
// frozen reader answers — the two differ exactly where getString swallows the
// library's exception, which is what the corpus's declared rows are about.
//
// This is NOT the four-stage device oracle: see README.md.
package tool.jsonpath

import com.google.gson.GsonBuilder
import io.legado.app.model.analyzeRule.AnalyzeByJSonPath
import java.io.File

data class FrozenSource(
    val path: String = "",
    val sha1: String = "",
    val role: String = "",
)

data class Library(
    val artifact: String = "",
    val sha256: String = "",
    val pinnedBy: String = "",
    val wraps: String = "",
)

data class Declared(
    val kind: String = "",
    val reason: String = "",
)

data class Case(
    val name: String,
    val document: String,
    val rule: String,
    val note: String = "",
    val declared: Declared? = null,
)

data class Fixtures(
    val baseline: String = "",
    val frozenSources: List<FrozenSource> = emptyList(),
    val library: Library = Library(),
    val note: String = "",
    val documents: Map<String, String> = emptyMap(),
    val cases: List<Case> = emptyList(),
)

/** The frozen field text, and what the raw read did. */
data class Row(
    val text: String?,
    val read: String,
)

fun main(args: Array<String>) {
    require(args.size == 2) { "usage: JsonPathOracleKt <fixtures.json> <golden.json>" }
    val gson = GsonBuilder()
        .setPrettyPrinting()
        .disableHtmlEscaping()
        .serializeNulls()
        .create()
    val fixtures = gson.fromJson(File(args[0]).readText(Charsets.UTF_8), Fixtures::class.java)
    check(fixtures.library.artifact == "com.jayway.jsonpath:json-path:2.9.0") {
        "fixtures.json must pin the json-path release the frozen reader wraps"
    }

    val golden = LinkedHashMap<String, Row>()
    for (case in fixtures.cases) {
        val document = fixtures.documents[case.document]
            ?: error("case ${case.name} names an unknown document ${case.document}")
        val first = read(document, case.rule)
        val second = read(document, case.rule)
        check(first == second) {
            "case ${case.name} is not deterministic; remove it from the corpus"
        }
        golden[case.name] = first
    }
    File(args[1]).writeText(gson.toJson(golden), Charsets.UTF_8)
    println("wrote ${golden.size} rows from ${fixtures.baseline} (${fixtures.library.artifact})")
}

private fun read(document: String, rule: String): Row {
    val reader = AnalyzeByJSonPath(document)
    val raw = runCatching { reader.getObject(rule) }
    return Row(
        text = reader.getString(rule),
        read = raw.fold({ "ok" }, { "error:${it.javaClass.name}" }),
    )
}
