// Actual getters bind the preserved minimal Book entity, with real mutable
// name/author properties. Their source-verified BookInfo merge/write-back order
// is transcribed here; this is not full BookInfo execution.
package tool.rulefield.bookvisibility

import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import java.io.File

private fun units(value: String) = value.map { it.code }
data class VisibilityRow(val type: String, val getterUnits: Map<String, List<Int>>,
    val finalNameUnits: List<Int>, val finalAuthorUnits: List<Int>)

fun main(args: Array<String>) {
    val gson = GsonBuilder().setPrettyPrinting().serializeNulls().create()
    val cases = gson.fromJson(File(args[0]).readText(), Array<JsonObject>::class.java)
    val rows = linkedMapOf<String, VisibilityRow>()
    for (case in cases) {
        fun read(): VisibilityRow {
            val book = Book(name = case["initialName"].asString, author = case["initialAuthor"].asString)
            val rule = AnalyzeRule(ruleData = book, source = BookSource()).setContent(case["content"].asString, "https://context-rules.test/book")
            val rules = case["rules"].asJsonObject
            val rename = case["canReName"].asBoolean
            val observed = linkedMapOf<String, List<Int>>()
            val name = rule.getString(rules["name"].asString)
            observed["name"] = units(name)
            if (name.isNotEmpty() && (rename || book.name.isEmpty())) book.name = name
            val author = rule.getString(rules["author"].asString)
            observed["author"] = units(author)
            if (author.isNotEmpty() && (rename || book.author.isEmpty())) book.author = author
            observed["kind"] = units(rule.getStringList(rules["kind"].asString)?.joinToString(",") ?: "")
            observed["wordCount"] = units(rule.getString(rules["wordCount"].asString))
            return VisibilityRow(book.javaClass.name, observed, units(book.name), units(book.author))
        }
        val actual = read()
        check(read() == actual)
        rows[case["name"].asString] = actual
    }
    File(args[1]).writeText(gson.toJson(rows) + "\n")
    println("${rows.size} repeated actual getters with preserved Book name/author; source-verified merge, not whole BookInfo")
}
