// Execute frozen AnalyzeRule/JSoup/JSONPath/Rhino at true content boundaries.
package tool.rulefield

import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import kotlinx.coroutines.Job
import io.legado.app.model.analyzeRule.AnalyzeByJSonPath
import org.apache.commons.text.StringEscapeUtils
import org.apache.commons.text.translate.EntityArrays
import org.jsoup.Jsoup
import java.io.File

private fun units(value: String) = value.map { it.code }

data class ReviewCase(val name: String, val rule: String = "", val content: String = "<p>body</p>",
    val type: String = "string", val form: String = "scalar", val unescape: Boolean = true,
    val url: Boolean = false, val selector: String = "li", val base: String = "https://review-rules.test/search")
data class ReviewRow(val type: String, val contentUnits: List<Int>, val values: List<List<Int>?>?,
    val error: String?, val count: String, val joinedUnits: List<Int>? = null)

fun main(args: Array<String>) {
    val gson = GsonBuilder().setPrettyPrinting().serializeNulls().create()
    val cases = gson.fromJson(File(args[0]).readText(), Array<JsonObject>::class.java).map { row ->
        ReviewCase(row["name"].asString, row["rule"]?.asString ?: "", row["content"]?.asString ?: "<p>body</p>",
            row["type"]?.asString ?: "string", row["form"]?.asString ?: "scalar",
            row["unescape"]?.asBoolean ?: true, row["url"]?.asBoolean ?: false,
            row["selector"]?.asString ?: "li", row["base"]?.asString ?: "https://review-rules.test/search")
    }
    val rows = linkedMapOf<String, ReviewRow>()
    for (case in cases) {
        fun read(): ReviewRow {
            val source = BookSource()
            val rule = AnalyzeRule(source = source).setContent(case.content, case.base)
            rule.setRedirectUrl(case.base)
            if (case.form == "items") {
                val nodes = Jsoup.parse(case.content).select(case.selector)
                val values = nodes.map { node ->
                    rule.setContent(node)
                    units(rule.getString(case.rule))
                }
                return ReviewRow(nodes.first()!!.javaClass.name, units(case.content), values, null, rule.get("count"))
            }
            val content: Any = when (case.type) {
                "string" -> case.content
                "node" -> Jsoup.parse(case.content).select(case.selector).first()!!
                "map" -> AnalyzeByJSonPath(case.content).getObject("$.item")!!
                "list" -> AnalyzeByJSonPath(case.content).getObject("$.list")!!
                "nativeObject" -> rule.evalJS("(" + case.content + ")")!!
                "entity" -> case.content
                else -> error("Unknown content type: ${case.type}")
            }
            rule.setContent(content)
            if (case.form == "cancelled") {
                val job = Job()
                job.cancel()
                rule.setCoroutineContext(job)
            }
            return try {
                val result = when (case.form) {
                    "list" -> rule.getStringList(case.rule)
                    "entity" -> listOf(StringEscapeUtils.unescapeHtml4(case.content))
                    else -> listOf(rule.getString(rule.splitSourceRule(case.rule), isUrl = case.url, unescape = case.unescape))
                }
                ReviewRow(content.javaClass.name, units(content.toString()),
                    (result as List<Any?>?)?.map { it?.let { units(it.toString()) } }, null, rule.get("count"),
                    if (case.form == "list") units(result?.joinToString(",") ?: "") else null)
            } catch (error: Throwable) {
                // Errors remain named observations, never fabricated extraction answers.
                ReviewRow(content.javaClass.name, units(content.toString()), null,
                    error.javaClass.name + ": " + error.message, rule.get("count"))
            }
        }
        val observed = read()
        val repeated = read()
        if (case.name == "native-array-scalar") {
            // NativeArray's Java toString carries an object identity. Preserve
            // both actual observations; this row is explicitly not comparable.
            rows[case.name + "/repeat"] = repeated
        } else {
            check(repeated == observed) { "Non-deterministic case ${case.name}" }
        }
        rows[case.name] = observed
    }
    val entities = sortedMapOf<String, List<Int>>()
    for (table in listOf(EntityArrays.BASIC_UNESCAPE, EntityArrays.ISO8859_1_UNESCAPE, EntityArrays.HTML40_EXTENDED_UNESCAPE)) {
        for ((name, value) in table) entities[name.toString()] = units(value.toString())
    }
    for ((name, expected) in entities) {
        val actual = units(StringEscapeUtils.unescapeHtml4(name))
        check(actual == expected)
        rows["table:$name"] = ReviewRow("java.lang.String", units(name), listOf(actual), null, "")
    }
    File(args[1]).writeText(gson.toJson(rows) + "\n")
    File(args[2]).writeText(gson.toJson(entities) + "\n")
    println("${rows.size} frozen typed/caller/table observations; NativeArray scalar identity notCompared; ${entities.size} exported HTML4 entities")
}
