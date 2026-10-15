// Actual preserved getters; fallback binding/order transcribes fixed
// BookChapterList. Original Chapter stub is not expanded with tag/flags.
package tool.rulefield.fallbackget
import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import java.io.File
private fun units(text:String)=text.map{it.code}
data class FallbackRow(val items:List<Map<String,List<Int>>>,val sourceVariables:Map<String,String>,val errorType:String?,val errorUnits:List<Int>?)
fun main(args:Array<String>){
 val gson=GsonBuilder().setPrettyPrinting().serializeNulls().create();val cases=gson.fromJson(File(args[0]).readText(),Array<JsonObject>::class.java);val rows=linkedMapOf<String,FallbackRow>()
 for(case in cases){
  fun read():FallbackRow{
   val source=BookSource();case["seed"].asJsonObject.entrySet().forEach{(k,v)->source.put(k,v.asString)}
   val rule=AnalyzeRule(source=source).setContent(case["content"].asString,case["redirectUrl"].asString)
   val items=mutableListOf<Map<String,List<Int>>>();var errorType:String?=null;var errorUnits:List<Int>?=null
   try{
    if(case["stage"].asString=="h1"){
     rule.getElements(case["listRule"].asString).forEachIndexed{index,item->
      rule.setContent(item,case["redirectUrl"].asString);val chapter=BookChapter();rule.chapter=chapter
      chapter.title=rule.getString(case["nameRule"].asString);chapter.url=rule.getString(case["urlRule"].asString)
      val tag=rule.getString(case["tagRule"].asString);val volume=rule.getString(case["volumeRule"].asString)
      // Fixed BookChapterList:229-243 precedes the title condition/VIP/pay.
      if(chapter.url.isEmpty())chapter.url=if(volume=="true")chapter.title+index else case["baseAddress"].asString
      if(chapter.title.isNotEmpty()){
       val vip=rule.getString(case["vipRule"].asString);val pay=rule.getString(case["payRule"].asString)
       items.add(linkedMapOf("name" to units(chapter.title),"address" to units(chapter.url),"tag" to units(tag),"volume" to units(volume),"vip" to units(vip),"pay" to units(pay)))
      }
     }
    }else{
     val chapter=BookChapter(title="chapter");rule.chapter=chapter
     val values=if(case["form"].asString=="list")rule.getStringList(case["rule"].asString)?:emptyList() else listOf(rule.getString(case["rule"].asString))
     items.add(linkedMapOf("value" to units(values.joinToString(","))))
    }
   }catch(error:Throwable){check(case["error"]?.asBoolean==true){"Unexpected ${case["name"]}: $error"};errorType=error.javaClass.name;errorUnits=units(error.message?:"")}
   return FallbackRow(items,listOf("trace","count","vipCount","payCount").associateWith{source.get(it)},errorType,errorUnits)
  }
  println("Executing "+case["name"].asString);val actual=read();check(read()==actual){"Non-deterministic ${case["name"]}"};rows[case["name"].asString]=actual
 }
 File(args[1]).writeText(gson.toJson(rows)+"\n");println("${rows.size} repeated actual auxiliary getters; not whole caller/entity or bare-marker extension parity")
}
