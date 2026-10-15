// F1 actual preserved getters with source-transcribed BookChapterList order.
// F2 metadata is not executed here: the original Book stub stays unchanged.
package tool.rulefield.nextbookstate

import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import java.io.File

private fun units(text: String) = text.map { it.code }
data class NextRow(val types: List<String>, val next: List<List<Int>>,
    val chapters: List<Map<String, List<Int>>>, val variables: Map<String, String>,
    val errorType: String?, val errorUnits: List<Int>?)

fun main(args: Array<String>) {
    val gson = GsonBuilder().setPrettyPrinting().serializeNulls().create()
    val cases = gson.fromJson(File(args[0]).readText(), Array<JsonObject>::class.java)
    val rows = linkedMapOf<String, NextRow>()
    for (case in cases) {
        fun read(): NextRow {
            val rule = AnalyzeRule(source = BookSource()).setContent(case["content"].asString, "https://next-book-state.test/toc")
            val types = mutableListOf<String>()
            val next = mutableListOf<List<Int>>()
            val chapters = mutableListOf<Map<String, List<Int>>>()
            var errorType: String? = null
            var errorUnits: List<Int>? = null
            try {
                // BookChapterList.kt:187-207 acquires the list, completes next,
                // then switches to item content at 216-254. This is auxiliary.
                val items = rule.getElements(case["listRule"].asString)
                types.addAll(items.map { it.javaClass.name })
                rule.getStringList(case["nextRule"].asString, isUrl = true)?.forEach { next.add(units(it)) }
                for (item in items) {
                    rule.setContent(item, "https://next-book-state.test/toc")
                    chapters.add(linkedMapOf(
                        "name" to units(rule.getString(case["nameRule"].asString)),
                        "address" to units(rule.getString(case["urlRule"].asString, isUrl = true))))
                }
            } catch (error: Throwable) {
                check(case["error"]?.asBoolean == true) { "Unexpected ${case["name"]}: $error" }
                errorType = error.javaClass.name
                errorUnits = units(error.message ?: "")
            }
            val variables = listOf("seed", "visited", "nextCount", "resolveCount").associateWith { rule.get(it) }
            return NextRow(types, next, chapters, variables, errorType, errorUnits)
        }
        println("Executing " + case["name"].asString)
        val actual = read()
        check(read() == actual) { "Non-deterministic ${case["name"]}" }
        rows[case["name"].asString] = actual
    }
    File(args[1]).writeText(gson.toJson(rows) + "\n")
    println("${rows.size} repeated actual auxiliary next/item observations; not whole caller or F2 entity parity")
}
