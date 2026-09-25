// The frozen `io.legado.app.data.entities` members `AnalyzeRule.kt` names, for
// the compile classpath only.
//
// The frozen entity files cannot be compiled on a desktop JVM: they are Room
// entities (`@Entity`/`@Ignore`/`@ColumnInfo`) and `BookSource.kt`/`BaseSource.kt`
// reach hutool, OkHttp's cookie jar, splitties and the app's crypto helpers.
// `AnalyzeRule.kt` reads from them only the values a rule script binds — the
// book's name and author, the chapter's title, the source's own address — and
// the `getVariable`/`putVariable` pair, whose frozen shape is
// `RuleDataInterface.kt` and is compiled from its own bytes.
//
// Every member here is declared because `AnalyzeRule.kt` names it; the bodies
// answer the same value the frozen entity would for a value the fixture set.
package io.legado.app.data.entities

import io.legado.app.help.JsExtensions
import io.legado.app.model.analyzeRule.RuleDataInterface

/** The frozen `BaseBook` (`BaseBook.kt`), reduced to what a rule reads. */
interface BaseBook : RuleDataInterface {
    var name: String
    var author: String
    var bookUrl: String
    var origin: String
}

/** The frozen `Book` (`Book.kt`), reduced to what a rule reads. */
data class Book(
    override var name: String = "",
    override var author: String = "",
    override var bookUrl: String = "",
    override var origin: String = "",
) : BaseBook {
    override val variableMap = HashMap<String, String>()
    override fun putBigVariable(key: String, value: String?) = Unit
    override fun getBigVariable(key: String): String? = null
}

/** The frozen `BookChapter` (`BookChapter.kt`), reduced to what a rule reads. */
data class BookChapter(
    var url: String = "",
    var title: String = "",
    var index: Int = 0,
) : RuleDataInterface {
    override val variableMap = HashMap<String, String>()
    override fun putBigVariable(key: String, value: String?) = Unit
    override fun getBigVariable(key: String): String? = null
}

/** The frozen `BookSource` (`BookSource.kt`), reduced to what a rule reads. */
data class BookSource(
    var bookSourceUrl: String = "",
    override var jsLib: String? = null,
) : BaseSource {
    override val variableMap = HashMap<String, String>()
    override fun putBigVariable(key: String, value: String?) = Unit
    override fun getBigVariable(key: String): String? = null

    /** The frozen `BaseSource.put` (`BaseSource.kt:220`), without the cache. */
    override fun put(key: String, value: String): String {
        variableMap[key] = value
        return value
    }

    /** The frozen `BaseSource.get` (`BaseSource.kt:228`), without the cache. */
    override fun get(key: String): String = variableMap[key] ?: ""

    override fun getTag(): String = ""
    override fun getKey(): String = bookSourceUrl
    override fun getSource(): BaseSource = this
}

/** The frozen `RssArticle` (`RssArticle.kt`), reduced to what a rule reads. */
class RssArticle : RuleDataInterface {
    override val variableMap = HashMap<String, String>()
    override fun putBigVariable(key: String, value: String?) = Unit
    override fun getBigVariable(key: String): String? = null
}

/** The frozen `BaseSource` (`BaseSource.kt`), reduced to what a rule reads. */
interface BaseSource : JsExtensions {
    val variableMap: HashMap<String, String>

    /** `jsLib`, the script library the frozen `getShareScope` reads. */
    var jsLib: String?

    fun putBigVariable(key: String, value: String?)
    fun getBigVariable(key: String): String?
    fun put(key: String, value: String): String
    fun get(key: String): String
    fun getTag(): String
    fun getKey(): String
}
