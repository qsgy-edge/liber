// Actual preserved AnalyzeRule getters; caller conditions/order are source-
// verified transcriptions, not whole BookChapterList/BookInfo execution.
// N5 retention is deliberately absent: the preserved Book stub lacks fields.
package tool.rulefield.calleredges

import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import java.io.File

private fun units(text: String) = text.map { it.code }
data class EdgeRow(val types: List<String>, val fields: Map<String, List<Int>>,
    val chapters: List<Map<String, List<Int>>>, val variables: Map<String, String>,
    val errorType: String?, val errorUnits: List<Int>?)

fun main(args: Array<String>) {
    val gson = GsonBuilder().setPrettyPrinting().serializeNulls().create()
    val cases = gson.fromJson(File(args[0]).readText(), Array<JsonObject>::class.java)
    val rows = linkedMapOf<String, EdgeRow>()
    for (case in cases) {
        fun read(): EdgeRow {
            val stage = case["stage"].asString
            val book = if (stage == "fallback" || stage == "detailToc") Book(bookUrl = "https://caller-edges.test/book") else null
            val rule = AnalyzeRule(ruleData = book, source = BookSource()).setContent(case["content"].asString, "https://caller-edges.test/book")
            case["seed"]?.asJsonObject?.entrySet()?.forEach { (key, value) -> rule.put(key, value.asString) }
            val types = mutableListOf<String>()
            val fields = linkedMapOf<String, List<Int>>()
            val chapters = mutableListOf<Map<String, List<Int>>>()
            var errorType: String? = null
            var errorUnits: List<Int>? = null
            try {
                when (stage) {
                    "toc" -> {
                        val rules = case["rules"].asJsonObject
                        for (item in rule.getElements(case["listRule"].asString)) {
                            types.add(item.javaClass.name)
                            rule.setContent(item, "https://caller-edges.test/toc")
                            val reads = linkedMapOf<String, List<Int>>()
                            // BookChapterList.kt:221-246, including the condition.
                            val name = rule.getString(rules["chapterName"].asString)
                            reads["chapterName"] = units(name)
                            reads["chapterUrl"] = units(rule.getString(rules["chapterUrl"].asString))
                            reads["updateTime"] = units(rule.getString(rules["updateTime"].asString))
                            reads["isVolume"] = units(rule.getString(rules["isVolume"].asString))
                            if (name.isNotEmpty()) {
                                reads["isVip"] = units(rule.getString(rules["isVip"].asString))
                                reads["isPay"] = units(rule.getString(rules["isPay"].asString))
                                chapters.add(reads)
                            }
                        }
                    }
                    "hostList" -> {
                        types.add(String::class.java.name)
                        fields["value"] = units(rule.getString(case["rule"].asString))
                    }
                    else -> {
                        types.add(book!!.javaClass.name)
                        case["initRule"]?.asString?.let { init ->
                            rule.setContent(rule.getElement(init), "https://caller-edges.test/book")
                        }
                        val name = rule.getString(case["nameRule"].asString)
                        fields["name"] = units(name)
                        if (name.isNotEmpty() && book.name.isEmpty()) book.name = name
                        // BookInfo.kt:148-151 still reads toc with canReName=false.
                        fields["toc"] = units(rule.getString(case["tocRule"].asString, isUrl = true))
                    }
                }
            } catch (error: Throwable) {
                check(case["error"]?.asBoolean == true) { "Unexpected ${case["name"]}: $error" }
                errorType = error.javaClass.name
                errorUnits = units(error.message ?: "")
            }
            val variables = listOf("v", "urlOrder", "volumeCount", "vipCount", "payCount", "count", "tocSeen", "tocCount", "initBook")
                .associateWith { rule.get(it) }
            return EdgeRow(types, fields, chapters, variables, errorType, errorUnits)
        }
        println("Executing " + case["name"].asString)
        val actual = read()
        check(read() == actual) { "Non-deterministic ${case["name"]}" }
        rows[case["name"].asString] = actual
    }
    File(args[1]).writeText(gson.toJson(rows) + "\n")
    println("${rows.size} repeated actual getter observations; source-transcribed callers, not whole callers or N5 entity parity")
}
