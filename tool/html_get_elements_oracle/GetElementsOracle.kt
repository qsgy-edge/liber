package tool.htmlelements

import com.google.gson.GsonBuilder
import com.google.gson.JsonParser
import io.legado.app.model.analyzeRule.AnalyzeRule
import org.jsoup.Jsoup
import java.io.File

fun main(args: Array<String>) {
    val fixture = JsonParser.parseString(File(args[0]).readText()).asJsonObject
    val rows = fixture.getAsJsonArray("rows").map { raw ->
        val row = raw.asJsonObject
        val analyze = AnalyzeRule()
        val doc = fixture.get("html").asString
        val context = row.get("contextSelector")?.asString
        analyze.setContent(if (context == null) doc else Jsoup.parse(doc).selectFirst(context)!!)
        val result = analyze.evalJS(row.get("script").asString)
        mapOf("id" to row.get("id").asString, "value" to JsonParser.parseString(result.toString()))
    }
    val golden = mapOf("corpus" to "HTML-GET-ELEMENTS-01", "execution" to "host-jvm", "rows" to rows)
    File(args[1]).writeText(GsonBuilder().setPrettyPrinting().create().toJson(golden) + "\n")
    println("executed ${rows.size} frozen HTML getElements rows")
}
