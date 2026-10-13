// Bounded continuation over the already compiled pinned AnalyzeRule classes.
// String callers create real Jsoup values inside the script; they are distinct
// from setContent(Elements), which remains a frozen-only observation.
package tool.rulefield.tail

import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import org.jsoup.Jsoup
import java.io.File

private fun units(value: String) = value.map { it.code }

data class TailRow(val type: String, val contentUnits: List<Int>,
    val values: List<List<Int>>?, val joinedUnits: List<Int>?,
    val count: String, val error: String?)

fun main(args: Array<String>) {
    val gson = GsonBuilder().setPrettyPrinting().serializeNulls().create()
    val cases = gson.fromJson(File(args[0]).readText(), Array<JsonObject>::class.java)
    val rows = linkedMapOf<String, TailRow>()
    for (case in cases) {
        fun read(): TailRow {
            val html = case["content"]?.asString ?: "<p>body</p>"
            val rule = AnalyzeRule(source = BookSource())
            val content: Any = when (case["type"]?.asString ?: "string") {
                "string" -> html
                "node" -> Jsoup.parse(html).select("li").first()!!
                "collection" -> Jsoup.parse(html).select("li")
                else -> error("Unsupported input type")
            }
            rule.setContent(content, "https://review-rules.test/book")
            return try {
                val list = case["form"]?.asString == "list"
                val values = if (list) rule.getStringList(case["rule"].asString)
                    else listOf(rule.getString(rule.splitSourceRule(case["rule"].asString),
                        unescape = case["unescape"]?.asBoolean ?: true))
                TailRow(content.javaClass.name, units(content.toString()),
                    values?.map { units(it) },
                    if (list) units(values?.joinToString(",") ?: "") else null,
                    rule.get("count"), null)
            } catch (error: Throwable) {
                TailRow(content.javaClass.name, units(content.toString()), null, null,
                    rule.get("count"), error.javaClass.name + ": " + error.message)
            }
        }
        val actual = read()
        check(read() == actual) { "Non-deterministic case ${case["name"]}" }
        check(actual.error == null) { "Unreached case ${case["name"]}: ${actual.error}" }
        rows[case["name"].asString] = actual
    }
    File(args[1]).writeText(gson.toJson(rows) + "\n")
    println("${rows.size} actual frozen tail observations, each repeated; one direct Elements input is frozen-only")
}
