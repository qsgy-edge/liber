// The frozen `io.legado.app.model.analyzeRule` members `AnalyzeRule.kt` names
// beside `RuleDataInterface.kt` (which is compiled from its own bytes), for the
// compile classpath only.
//
// The three analysis classes cannot be compiled here: `AnalyzeByJSoup`/`AnalyzeByXPath`
// wrap jsoup (whose jar this harness does not pin) and `AnalyzeByJSonPath` wraps
// json-path. This corpus decides the *replacement* path around an extraction,
// not the extraction itself — the product's Rust adapter and
// `tool/jsonpath_oracle/` own those — so each stub records the rule it was asked
// for and answers the value the current fixture case declares as the extraction
// result. Reaching one of them without a declared answer fails the run rather
// than answering an empty string.
package io.legado.app.model.analyzeRule

/**
 * The extraction answer one case declares: what the frozen selector engine
 * returns for the field's rule part. Set by the harness before it runs a case.
 */
object ExtractionAnswer {
    var declared: String? = null
    var askedRule: String? = null

    fun reset() {
        declared = null
        askedRule = null
    }

    fun answer(rule: String): String {
        askedRule = rule
        return declared
            ?: error("the corpus declares no extraction answer for rule `$rule`")
    }
}

/** The frozen `AnalyzeByJSoup` (`AnalyzeByJSoup.kt`), for the compile
 * classpath only. */
class AnalyzeByJSoup(private val content: Any?) {
    fun getString(rule: String): String = ExtractionAnswer.answer(rule)
    fun getString0(rule: String): String = ExtractionAnswer.answer(rule)
    fun getStringList(rule: String): List<String>? = listOf(ExtractionAnswer.answer(rule))
    fun getElements(rule: String): List<Any> = listOf(ExtractionAnswer.answer(rule))
    fun getElement(rule: String): Any? = ExtractionAnswer.answer(rule)
    override fun toString(): String = "AnalyzeByJSoup($content)"
}

/** The frozen `AnalyzeByXPath` (`AnalyzeByXPath.kt`), for the compile classpath
 * only. */
class AnalyzeByXPath(private val content: Any?) {
    fun getString(rule: String): String = ExtractionAnswer.answer(rule)
    fun getStringList(rule: String): List<String>? = listOf(ExtractionAnswer.answer(rule))
    fun getElements(rule: String): List<Any> = listOf(ExtractionAnswer.answer(rule))
    override fun toString(): String = "AnalyzeByXPath($content)"
}

/** The frozen `AnalyzeByJSonPath` (`AnalyzeByJSonPath.kt`), for the compile
 * classpath only. */
class AnalyzeByJSonPath(private val content: Any?) {
    fun getString(rule: String): String = ExtractionAnswer.answer(rule)
    fun getStringList(rule: String): List<String>? = listOf(ExtractionAnswer.answer(rule))
    fun getObject(rule: String): Any? = ExtractionAnswer.answer(rule)
    fun getList(rule: String): List<Any> = listOf(ExtractionAnswer.answer(rule))
    override fun toString(): String = "AnalyzeByJSonPath($content)"
}
