// Actual isUrl getter normalization and subsequent empty-URL getter read.
// Caller fallback is transcribed; no full Chapter/URI/flag entity claim.
package tool.rulefield.relativefallback
import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.BookChapter
import io.legado.app.model.analyzeRule.AnalyzeRule
import java.io.File
private fun units(s:String)=s.map{it.code}
data class RelativeRow(val baseAddress:List<Int>,val beforeFallback:List<Int>,val vipUrl:List<Int>)
fun main(args:Array<String>){
 val gson=GsonBuilder().setPrettyPrinting().create();val cases=gson.fromJson(File(args[0]).readText(),Array<JsonObject>::class.java);val rows=linkedMapOf<String,RelativeRow>()
 for(case in cases){
  fun read():RelativeRow{
   val source=BookSource();val readBase=AnalyzeRule(source=source).setContent("{}",case["inputBase"].asString);readBase.setRedirectUrl(case["inputBase"].asString)
   val base=if(case["stage"].asString=="initial")readBase.getString(case["rule"].asString,isUrl=true) else readBase.getStringList(case["rule"].asString,isUrl=true)!!.single()
   val rule=AnalyzeRule(source=source).setContent("<li>chapter</li>",base);rule.setRedirectUrl(case["responseUrl"].asString);val chapter=BookChapter();rule.chapter=chapter
   chapter.title=rule.getString("{{'chapter'}}");chapter.url=rule.getString("{{''}}")
   val before=rule.getString("@js:String(chapter.url)")
   // BookChapterList229-243: ordinary fallback is original base, then VIP.
   if(chapter.url.isEmpty())chapter.url=base
   return RelativeRow(units(base),units(before),units(rule.getString("@js:String(chapter.url)")))
  }
  println("Executing "+case["name"].asString);val actual=read();check(read()==actual){"Nondeterministic ${case["name"]}"};rows[case["name"].asString]=actual
 }
 File(args[1]).writeText(gson.toJson(rows)+"\n");println("${rows.size} repeated actual relative URL/fallback getter observations; not whole caller/finalURI")
}
