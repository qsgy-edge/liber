// Actual preserved chapter/title getters; caller binding/order is a pinned
// BookChapterList transcription. Original BookChapter stub is unchanged.
package tool.rulefield.tocbinding
import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import java.io.File
private fun units(text: String) = text.map { it.code }
data class BindingRow(val items: List<Map<String,List<Int>>>, val sourceVariables: Map<String,String>, val errorType: String?, val errorUnits: List<Int>?)
fun main(args: Array<String>) {
    val gson=GsonBuilder().setPrettyPrinting().serializeNulls().create()
    val cases=gson.fromJson(File(args[0]).readText(),Array<JsonObject>::class.java)
    val rows=linkedMapOf<String,BindingRow>()
    for (case in cases) {
        fun read(): BindingRow {
            val source=BookSource()
            source.put("title","stored")
            val rule=AnalyzeRule(source=source).setContent(case["content"].asString,"https://toc-binding.test/toc")
            val items=mutableListOf<Map<String,List<Int>>>()
            var errorType:String?=null; var errorUnits:List<Int>?=null
            try {
                for (item in rule.getElements(case["listRule"].asString)) {
                    rule.setContent(item,"https://toc-binding.test/toc")
                    val chapter=BookChapter()
                    rule.chapter=chapter
                    chapter.title=rule.getString(case["nameRule"].asString)
                    chapter.url=rule.getString(case["urlRule"].asString)
                    val tag=rule.getString(case["tagRule"].asString)
                    // Stub has no tag/isVolume/isVip/isPay. Actual getters can
                    // still execute at pinned caller turns; no entity added.
                    rule.getString(case["volumeRule"].asString)
                    if(chapter.title.isNotEmpty()) {
                        rule.getString(case["vipRule"].asString)
                        rule.getString(case["payRule"].asString)
                        items.add(linkedMapOf("name" to units(chapter.title),"address" to units(chapter.url),"tag" to units(tag)))
                    }
                }
            } catch(error:Throwable) {
                check(case["error"]?.asBoolean==true){"Unexpected ${case["name"]}: $error"}
                errorType=error.javaClass.name;errorUnits=units(error.message?:"")
            }
            return BindingRow(items,listOf("trace","beforeError","vipCount","payCount").associateWith{source.get(it)},errorType,errorUnits)
        }
        println("Executing "+case["name"].asString)
        val actual=read();check(read()==actual){"Non-deterministic ${case["name"]}"};rows[case["name"].asString]=actual
    }
    File(args[1]).writeText(gson.toJson(rows)+"\n")
    println("${rows.size} repeated actual auxiliary chapter/title observations; not whole caller or tag entity execution")
}
