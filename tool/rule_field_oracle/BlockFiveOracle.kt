// Execute only the five review findings against the preserved pinned classes.
// Sequence rows call the real getters in the frozen source's caller order;
// BookList itself is not compiled/executed by this bounded harness.
package tool.rulefield.block

import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeByJSonPath
import org.jsoup.Jsoup
import java.io.File

private fun units(value: String) = value.map { it.code }
data class ReadRow(val field: String, val values: List<List<Int>>?, val joinedUnits: List<Int>?)
data class ItemRow(val type: String, val contentUnits: List<Int>, val reads: List<ReadRow>)
data class BlockError(val errorType: String, val errorUnits: List<Int>)
data class BlockRow(val items: List<ItemRow>, val variables: Map<String, String>)

fun main(args: Array<String>) {
    val gson = GsonBuilder().setPrettyPrinting().serializeNulls().create()
    val cases = gson.fromJson(File(args[0]).readText(), Array<JsonObject>::class.java)
    val rows = linkedMapOf<String, Any>()
    for (case in cases) {
        fun read(): BlockRow {
            val text = case["content"]?.asString ?: "<p>body</p>"
            val rule = AnalyzeRule(source = BookSource())
            val type = case["type"]?.asString ?: "string"
            val contents: List<Any> = when (type) {
                "node" -> {
                    val nodes = Jsoup.parse(text).select("li")
                    if (case["items"]?.asBoolean == true) nodes.toList() else listOf(nodes.first()!!)
                }
                "map" -> listOf(AnalyzeByJSonPath(text).getObject(case["selector"]?.asString ?: "$.item")!!)
                "nativeObject" -> listOf(rule.evalJS("(" + text + ")")!!)
                "string" -> listOf(text)
                else -> error("Unknown content type")
            }
            val readings = case["reads"]?.asJsonArray?.map { it.asJsonObject } ?: listOf(case)
            val items = contents.map { content ->
                rule.setContent(content, "https://review-rules.test/" + if (case["items"]?.asBoolean == true || case["url"]?.asBoolean == true || case["name"].asString.startsWith("json-")) "search" else "book")
                val observed = readings.map { field ->
                    val list = field["form"]?.asString == "list"
                    val values = if (list) rule.getStringList(field["rule"].asString)
                        else listOf(rule.getString(rule.splitSourceRule(field["rule"].asString),
                            isUrl = field["url"]?.asBoolean ?: false,
                            unescape = field["unescape"]?.asBoolean ?: true))
                    ReadRow(field["field"]?.asString ?: "value", values?.map { units(it) },
                        if (list) units(values?.joinToString(",") ?: "") else null)
                }
                ItemRow(content.javaClass.name, units(content.toString()), observed)
            }
            return BlockRow(items, listOf("count", "saved", "v", "order").associateWith { rule.get(it) })
        }
        println("Executing " + case["name"].asString)
        fun observe(): Any = try { read() } catch (error: Throwable) {
            check(case["error"]?.asBoolean == true) { "Unexpected failure ${case["name"]}: $error" }
            BlockError(error.javaClass.name, units(error.message ?: ""))
        }
        val actual = observe()
        check(observe() == actual) { "Non-deterministic case ${case["name"]}" }
        rows[case["name"].asString] = actual
    }
    File(args[1]).writeText(gson.toJson(rows) + "\n")
    println("${rows.size} actual frozen finding observations, each repeated; sequence rows execute getters, not full BookList")
}
