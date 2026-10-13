// Actual getString plus the compiled frozen HtmlFormatter.format; no BookList
// or BookInfo orchestration is emulated or claimed by these host observations.
package tool.rulefield.intro

import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeByJSonPath
import io.legado.app.utils.HtmlFormatter
import org.jsoup.Jsoup
import java.io.File

private fun units(value: String) = value.map { it.code }
data class IntroRow(val type: String, val contentUnits: List<Int>,
    val getterUnits: List<Int>, val formattedUnits: List<Int>, val count: String)

fun main(args: Array<String>) {
    val gson = GsonBuilder().setPrettyPrinting().serializeNulls().create()
    val cases = gson.fromJson(File(args[0]).readText(), Array<JsonObject>::class.java)
    val rows = linkedMapOf<String, IntroRow>()
    for (case in cases) {
        fun read(): IntroRow {
            val text = case["content"].asString
            val content: Any = when (case["type"].asString) {
                "node" -> Jsoup.parse(text).select(".result").first()!!
                "map" -> AnalyzeByJSonPath(text).getObject(case["selector"].asString)!!
                "string" -> text
                else -> error("Unknown input type")
            }
            val rule = AnalyzeRule(source = BookSource()).setContent(content, "http://rules.test/search")
            val actual = if (case["form"]?.asString == "list")
                rule.getStringList(case["rule"].asString)?.joinToString(",") ?: ""
                else rule.getString(rule.splitSourceRule(case["rule"].asString),
                    isUrl = case["url"]?.asBoolean ?: false,
                    unescape = case["unescape"]?.asBoolean ?: true)
            return IntroRow(content.javaClass.name, units(content.toString()),
                units(actual), units(HtmlFormatter.format(actual)), rule.get("count"))
        }
        val actual = read()
        check(read() == actual)
        rows[case["name"].asString] = actual
    }
    File(args[1]).writeText(gson.toJson(rows) + "\n")
    println("${rows.size} repeated actual typed getString and frozen HtmlFormatter.format observations; host JVM only")
}
