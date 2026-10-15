// Bounded actual AnalyzeRule caller probes. Sequence rows use source-verified
// supported caller order, not whole BookInfo/BookChapterList execution.
package tool.rulefield.context

import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import kotlinx.coroutines.Job
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import java.io.File

private fun units(value: String) = value.map { it.code }
data class ContextRead(val field: String, val values: List<List<Int>>?, val joinedUnits: List<Int>?)
data class ContextItem(val type: String, val contentUnits: List<Int>, val reads: List<ContextRead>)
data class ContextRow(val items: List<ContextItem>, val variables: Map<String, String>, val errorType: String?, val errorUnits: List<Int>?)

fun main(args: Array<String>) {
    val gson = GsonBuilder().setPrettyPrinting().serializeNulls().create()
    val cases = gson.fromJson(File(args[0]).readText(), Array<JsonObject>::class.java)
    val rows = linkedMapOf<String, ContextRow>()
    for (case in cases) {
        fun read(): ContextRow {
            val text = case["content"].asString
            val rule = AnalyzeRule(source = BookSource()).setContent(text, "https://context-rules.test/book")
            val node = case["type"]?.asString == "node"
            val contents: List<Any> = if (!node) listOf(text) else {
                val attached = if (case["items"]?.asBoolean == true)
                    rule.getElements(case["listRule"]?.asString ?: "li").map { it as Element }
                    else listOf(Jsoup.parse(text).select(case["selector"]?.asString ?: "li").first()!!)
                if (case["detached"]?.asBoolean == true)
                    attached.map { Jsoup.parse(it.outerHtml()).body().children().first()!! }
                    else attached
            }
            val readings = case["reads"]?.asJsonArray?.map { it.asJsonObject } ?: listOf(case)
            val items = mutableListOf<ContextItem>()
            var errorType: String? = null
            var errorUnits: List<Int>? = null
            try {
                for (content in contents) {
                    rule.setContent(content, "https://context-rules.test/book")
                    if (case["cancelled"]?.asBoolean == true) {
                        val job = Job()
                        job.cancel()
                        rule.setCoroutineContext(job)
                    }
                    val observed = readings.map { field ->
                        val list = field["form"]?.asString == "list"
                        val values = if (list) rule.getStringList(field["rule"].asString)
                            else listOf(rule.getString(rule.splitSourceRule(field["rule"].asString),
                                isUrl = field["url"]?.asBoolean ?: false,
                                unescape = field["unescape"]?.asBoolean ?: true))
                        ContextRead(field["field"]?.asString ?: "value", values?.map { units(it) },
                            if (list) units(values?.joinToString(",") ?: "") else null)
                    }
                    items.add(ContextItem(content.javaClass.name, units(content.toString()), observed))
                }
            } catch (error: Throwable) {
                check(case["error"]?.asBoolean == true) { "Unexpected ${case["name"]}: $error" }
                errorType = error.javaClass.name
                errorUnits = units(error.message ?: "")
            }
            return ContextRow(items, listOf("count", "saved", "v", "order").associateWith { rule.get(it) }, errorType, errorUnits)
        }
        println("Executing " + case["name"].asString)
        val actual = read()
        check(read() == actual) { "Non-deterministic ${case["name"]}" }
        rows[case["name"].asString] = actual
    }
    File(args[1]).writeText(gson.toJson(rows) + "\n")
    println("${rows.size} repeated actual read-context observations; host JVM, no whole caller class claim")
}
