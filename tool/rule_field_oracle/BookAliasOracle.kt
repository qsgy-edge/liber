// Real AnalyzeRule.get and BaseSource.get with/without the preserved Book.
package tool.rulefield.bookalias
import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import java.io.File
fun main(args: Array<String>) {
    val gson = GsonBuilder().setPrettyPrinting().create()
    val cases = gson.fromJson(File(args[0]).readText(), Array<JsonObject>::class.java)
    val rows = linkedMapOf<String, List<Int>>()
    for (case in cases) {
        fun read(): List<Int> {
            val source = BookSource()
            source.put("bookName", "stored")
            source.put("ordinary", "value")
            val book = case["bookName"]?.asString?.let { Book(name = it) }
            val rule = AnalyzeRule(ruleData = book, source = source).setContent("{}")
            return rule.evalJS(case["script"].asString).toString().map { it.code }
        }
        val actual = read()
        check(read() == actual)
        rows[case["name"].asString] = actual
    }
    File(args[1]).writeText(gson.toJson(rows) + "\n")
    println("${rows.size} actual repeated bookName alias/source/ordinary fallback observations")
}
