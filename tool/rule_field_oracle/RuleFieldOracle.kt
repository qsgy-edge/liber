// Execute the deciding AnalyzeRule class, not a transcription of its mode switch.
// ExtractionAnswer deliberately has NO declared answer: any extraction is a
// named failure. These rows prove classification, not JSoup/JSONPath extraction.
package tool.rulefield

import com.google.gson.GsonBuilder
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.ExtractionAnswer
import java.io.File

data class Case(val name: String, val rule: String)
data class Row(val mode: String, val value: String?, val extraction: String?, val error: String?)

fun main(args: Array<String>) {
    val gson = GsonBuilder().setPrettyPrinting().disableHtmlEscaping().serializeNulls().create()
    val cases = gson.fromJson(File(args[0]).readText(), Array<Case>::class.java)
    val rows = linkedMapOf<String, Row>()
    for (content in listOf("<p>body</p>", "<root>body</root>", "{\"name\":\"body\"}")) {
        val format = when { content.startsWith("{") -> "json"; content.startsWith("<root>") -> "xml"; else -> "html" }
        for (case in cases) {
            fun read(): Row {
                ExtractionAnswer.reset()
                val analyzer = AnalyzeRule().setContent(content, "https://rules.test/")
                val mode = analyzer.splitSourceRule(case.rule).first().mode.toString()
                return try {
                    Row(mode, analyzer.getString(case.rule, unescape = false), ExtractionAnswer.askedRule, null)
                } catch (error: IllegalStateException) {
                    check(error.message?.startsWith("the corpus declares no extraction answer") == true)
                    Row(mode, null, ExtractionAnswer.askedRule, error.message)
                }
            }
            val row = read()
            check(read() == row) { "Non-deterministic row: $format/${case.name}" }
            rows["$format/${case.name}"] = row
        }
    }
    File(args[1]).writeText(gson.toJson(rows) + "\n")
    println("${rows.size} deterministic frozen classification rows; extraction unavailable/fail-closed")
}
